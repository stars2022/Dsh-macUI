import AppKit

final class MainViewController: NSViewController, SidebarViewControllerDelegate, ConversationViewControllerDelegate {
    private let sidebar = SidebarViewController()
    private let conversation = ConversationViewController()
    private let details = DetailsViewController()
    private let api = HarnessAPI.shared
    private var sessions: [SessionSummary] = []
    private var current: SessionSummary?
    private var history: [ConversationItem] = []
    private var models: [ModelChoice] = []
    private var currentModel: String?
    private var settingsController: SettingsWindowController?
    private var refreshWorkItem: DispatchWorkItem?

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "DeepSeekHarnessMainSplit"
        addChild(sidebar); addChild(conversation); addChild(details)
        split.addArrangedSubview(sidebar.view); split.addArrangedSubview(conversation.view); split.addArrangedSubview(details.view)
        sidebar.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        sidebar.view.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        sidebar.view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sidebar.delegate = self
        conversation.delegate = self
        details.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        details.view.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        details.onClose = { [weak self] in self?.details.view.isHidden = true }
        view = split
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let split = view as? NSSplitView, split.subviews.count == 3 { split.setPosition(280, ofDividerAt: 0); split.setPosition(max(720, split.bounds.width - 310), ofDividerAt: 1) }
        api.onEvent = { [weak self] in self?.scheduleRefresh() }
        api.onConnectionState = { [weak self] connected in self?.conversation.setConnectionStatus(connected) }
        api.connectEvents()
        refresh(selectNewest: true)
    }

    deinit { api.disconnectEvents() }

    @objc func newSessionFromMenu() { sidebarDidRequestNewSession(sidebar) }
    @objc func showSettingsFromMenu() { sidebarDidRequestSettings(sidebar) }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(selectNewest: false) }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func refresh(selectNewest: Bool) {
        api.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions):
                self.sessions = sessions
                let selectedId = self.current?.id
                if let selectedId, let updated = sessions.first(where: { $0.id == selectedId }) { self.current = updated }
                else if selectNewest { self.current = sessions.first }
                self.sidebar.setSessions(sessions, currentId: self.current?.id)
                if let current = self.current { self.loadSession(current) }
            case let .failure(error): self.showAPIError(error)
            }
        }
    }

    private func loadSession(_ session: SessionSummary) {
        current = session
        sidebar.setSessions(sessions, currentId: session.id)
        let group = DispatchGroup()
        var loadedHistory: [ConversationItem] = history
        var loadedModels = models
        var loadedKey = currentModel
        var firstError: Error?
        group.enter()
        api.history(sessionId: session.id) { result in
            switch result { case let .success(snapshot): loadedHistory = snapshot.items; case let .failure(error): firstError = error }
            group.leave()
        }
        group.enter()
        api.models(sessionId: session.id) { result in
            switch result { case let .success(value): loadedModels = value.choices; loadedKey = value.current; case .failure: break }
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.current?.id == session.id else { return }
            self.history = loadedHistory; self.models = loadedModels; self.currentModel = loadedKey
            self.conversation.display(session: self.current ?? session, items: loadedHistory, models: loadedModels, currentModel: loadedKey)
            if let firstError { self.showAPIError(firstError) }
        }
    }

    func sidebarDidRequestNewSession(_ sidebar: SidebarViewController) {
        let cwd = current?.cwd ?? sessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        api.createSession(cwd: cwd) { [weak self] result in
            switch result {
            case let .success(id): self?.refreshAndOpen(id)
            case let .failure(error): self?.showAPIError(error)
            }
        }
    }

    func sidebar(_ sidebar: SidebarViewController, didSelect session: SessionSummary) { history = []; models = []; currentModel = nil; loadSession(session) }
    func sidebarDidRequestSettings(_ sidebar: SidebarViewController) {
        let controller = settingsController ?? SettingsWindowController()
        controller.onServerChanged = { [weak self] in self?.api.connectEvents(); self?.refresh(selectNewest: true) }
        settingsController = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func sidebar(_ sidebar: SidebarViewController, didRequestRename session: SessionSummary) {
        let alert = NSAlert(); alert.messageText = "重命名会话"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: session.displayTitle); field.frame = NSRect(x: 0, y: 0, width: 300, height: 26); alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        api.rename(sessionId: session.id, title: field.stringValue) { [weak self] result in if case let .failure(error) = result { self?.showAPIError(error) }; self?.refresh(selectNewest: false) }
    }

    func conversationDidSubmit(_ controller: ConversationViewController, text: String) {
        guard let current else { sidebarDidRequestNewSession(sidebar); return }
        history.append(.user(text: text, time: Date()))
        let running = current.withRunning(true, blank: false, updatedAt: Date())
        self.current = running
        conversation.display(session: running, items: history, models: models, currentModel: currentModel)
        api.prompt(sessionId: current.id, text: text) { [weak self] result in
            if case let .failure(error) = result { self?.showAPIError(error) }
            self?.scheduleRefresh()
        }
    }
    func conversationDidRequestStop(_ controller: ConversationViewController) { guard let current else { return }; api.cancel(sessionId: current.id) { [weak self] result in if case let .failure(error) = result { self?.showAPIError(error) }; self?.scheduleRefresh() } }
    func conversation(_ controller: ConversationViewController, didSelectModel choice: ModelChoice) { guard let current else { return }; api.selectModel(sessionId: current.id, choice: choice) { [weak self] result in if case let .failure(error) = result { self?.showAPIError(error) } else { self?.currentModel = choice.key } } }
    func conversation(_ controller: ConversationViewController, didSelectPermission permission: String) { guard let current else { return }; api.setPermission(sessionId: current.id, permission: permission) { [weak self] result in if case let .failure(error) = result { self?.showAPIError(error) }; self?.scheduleRefresh() } }
    func conversation(_ controller: ConversationViewController, didSelectTool name: String, detail: String) { details.view.isHidden = false; details.display(name: name, detail: detail) }

    private func refreshAndOpen(_ id: String) {
        api.listSessions { [weak self] result in
            guard let self else { return }
            switch result { case let .success(sessions): self.sessions = sessions; if let session = sessions.first(where: { $0.id == id }) { self.history = []; self.models = []; self.loadSession(session); self.conversation.focusComposer() }; case let .failure(error): self.showAPIError(error) }
        }
    }
    private func showAPIError(_ error: Error) { let alert = NSAlert(error: error); if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() } }
}
