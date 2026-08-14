import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var sessions: [SessionSummary] = []
    @Published var workspaces: [WorkspaceSummary] = []
    @Published var archivedSessionIds: Set<String> = []
    @Published var sessionSearchHits: [SessionSearchHit] = []
    @Published var sessionGroupMode: SessionGroupMode = SessionGroupMode(rawValue: UserDefaults.standard.string(forKey: "sessionGroupMode") ?? "workspace") ?? .workspace {
        didSet { UserDefaults.standard.set(sessionGroupMode.rawValue, forKey: "sessionGroupMode") }
    }
    @Published var sessionOrderMode: SessionOrderMode = SessionOrderMode(rawValue: UserDefaults.standard.string(forKey: "sessionOrderMode") ?? "manual") ?? .manual {
        didSet { UserDefaults.standard.set(sessionOrderMode.rawValue, forKey: "sessionOrderMode") }
    }
    @Published var sessionSearchLoading = false
    @Published var sessionSearchHasMore = false
    @Published var feedback: [String: MessageFeedbackItem] = [:]
    @Published var agentPresets: [AgentPresetEntry] = []
    @Published var agentPresetAuthorable = false
    @Published var agentPresetHasDocument = false
    @Published var agentPresetContent: String?
    @Published var pluginInventory: [PluginInventoryEntry] = []
    @Published var pluginInventoryLoading = false
    @Published var pluginInventoryError: String?
    @Published var pluginSettings: PluginSettingsSnapshot?
    @Published var pluginSettingsLoading = false
    @Published var pluginSettingsError: String?
    @Published var hostSettings: HostSettingsSnapshot?
    @Published var hostSettingsLoading = false
    @Published var hostSettingsError: String?
    @Published var settingsDocumentOpening = false
    @Published var cordisInventory: [CordisInventoryRow] = []
    @Published var cordisInventoryLoading = false
    @Published var cordisInventoryError: String?
    @Published var cordisActionBusy: Set<String> = []
    @Published var cordisActionErrors: [String: String] = [:]
    @Published var modelProviders: [ModelProviderSettings] = []
    @Published var modelProvidersWritable = false
    @Published var modelProvidersLoading = false
    @Published var modelProvidersError: String?
    @Published var subagents: [String: [SubagentEntry]] = [:]
    @Published var subagentParentAvailable: [String: Bool] = [:]
    @Published var subagentParentId: String?
    @Published private(set) var subagentModesById: [String: String] = [:]
    @Published var current: SessionSummary?
    @Published var history: [ConversationItem] = []
    @Published var trajectory: [TrajectoryTurn] = []
    @Published var models: [ModelChoice] = []
    @Published var currentModel: ModelSelection?
    @Published var modelCatalogLoading = false
    @Published var modelCatalogError: String?
    @Published var modelCatalogFailures: [ModelCatalogFailure] = []
    @Published var currentModelRoutable = true
    @Published var modelSelectionBusy = false
    @Published var commands: [CommandDescriptor] = []
    @Published var connectionText = "正在连接…"
    @Published var errorText: String?
    @Published var isLoading = false
    @Published var detail: ToolDetail?
    @Published var settingsPresented = false
    @Published var interactions: [PendingInteraction] = []
    @Published var interactionBusy = false
    @Published var projections = SessionProjections()
    @Published var queues: [String: [QueuedMessage]] = [:]
    @Published var jobs: [String: [BackgroundJob]] = [:]
    @Published var draftImages: [DraftImage] = []
    @Published var dockBusy = false
    @Published var permissionSelectionBusy = false
    @Published var planSelectionBusy = false
    @Published var sessionLogExportBusy = false
    @Published var appearance = UserDefaults.standard.integer(forKey: "appearance") {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    @Published var compactConversationDisplay = UserDefaults.standard.bool(forKey: "compactConversationDisplay") {
        didSet { UserDefaults.standard.set(compactConversationDisplay, forKey: "compactConversationDisplay") }
    }

    struct ToolDetail: Identifiable {
        let id = UUID()
        let tool: ToolCall
    }

    var colorScheme: ColorScheme? {
        switch appearance { case 1: return .light; case 2: return .dark; default: return nil }
    }

    private let api = HarnessAPI.shared
    private var started = false
    private var refreshWorkItem: DispatchWorkItem?
    private var streamingSteps: [String: StreamingAssistantAccumulator] = [:]
    private var pendingStreamKeys: Set<String> = []
    private var streamingRenderWorkItem: DispatchWorkItem?
    private var searchGeneration = 0
    @Published var currentSubagentMode: String?

    func start() {
        guard !started else { return }
        started = true
        api.onEvent = nil
        api.onMuxFrame = { [weak self] payload in self?.handleMuxFrame(payload) }
        api.onConnectionState = { [weak self] connected in
            self?.connectionText = connected ? "已连接" : "正在重新连接…"
        }
        api.connectEvents()
        loadAgentPresets()
        loadHostSettings()
        loadCordisInventory()
        refresh(selectNewest: true)
    }

    func reconnect() {
        api.connectEvents()
        connectionText = "正在连接…"
        refresh(selectNewest: true)
    }

    func refresh() { refresh(selectNewest: current == nil) }

    func refreshWorkspaces() {
        api.listWorkspaces { [weak self] result in
            guard let self else { return }
            if case let .success(value) = result {
                self.workspaces = value.items
                self.archivedSessionIds = Set(value.archivedSessionIds)
                self.sessions.removeAll { self.archivedSessionIds.contains($0.id) }
            }
        }
    }

    func createWorkspace(path: String) {
        api.createWorkspace(path: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(workspace): self.workspaces.insert(workspace, at: 0); self.createSession(workspace: workspace)
            case let .failure(error): self.show(error)
            }
        }
    }

    func renameWorkspace(_ workspace: WorkspaceSummary, to title: String) {
        api.renameWorkspace(id: workspace.id, title: title) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(updated): self.workspaces = self.workspaces.map { $0.id == updated.id ? updated : $0 }
            case let .failure(error): self.show(error)
            }
        }
    }

    func deleteWorkspace(_ workspace: WorkspaceSummary) {
        api.deleteWorkspace(id: workspace.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.workspaces.removeAll { $0.id == workspace.id }; self.refresh()
            case let .failure(error): self.show(error)
            }
        }
    }

    func reorderWorkspaces(from sourceID: String, before beforeID: String?) {
        let old = workspaces
        let without = old.filter { $0.id != sourceID }
        let index = beforeID.flatMap { id in without.firstIndex(where: { $0.id == id }) } ?? without.count
        guard let source = old.first(where: { $0.id == sourceID }) else { return }
        var next = without
        next.insert(source, at: min(index, next.count))
        workspaces = next
        api.insertWorkspaceBefore(id: sourceID, beforeId: beforeID) { [weak self] result in
            if case let .failure(error) = result { self?.workspaces = old; self?.show(error) }
            else { self?.refreshWorkspaces() }
        }
    }

    func reorderSessions(in workspace: WorkspaceSummary, sourceID: String, before beforeID: String?) {
        let old = workspaces
        guard let current = old.first(where: { $0.id == workspace.id }) else { return }
        var ids = current.sessionIds.filter { $0 != sourceID }
        let index = beforeID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(sourceID, at: min(index, ids.count))
        guard let updated = WorkspaceSummary(json: ["workspaceId": current.id, "path": current.path, "title": current.name, "sessionIds": ids, "createdAt": ISO8601DateFormatter().string(from: current.createdAt), "updatedAt": ISO8601DateFormatter().string(from: Date())]) else { return }
        workspaces = old.map { $0.id == current.id ? updated : $0 }
        api.insertSession(workspaceId: current.id, sessionId: sourceID, beforeSessionId: beforeID) { [weak self] result in
            if case let .failure(error) = result { self?.workspaces = old; self?.show(error) }
            else if case let .success(server) = result { self?.workspaces = self?.workspaces.map { $0.id == server.id ? server : $0 } ?? [] }
        }
    }

    func archive(_ session: SessionSummary) {
        api.archiveSession(session.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.archivedSessionIds.insert(session.id)
                self.sessions.removeAll { $0.id == session.id }
                if self.current?.id == session.id {
                    self.detail = nil
                    self.current = self.sessions.first
                }
                self.refresh()
            case let .failure(error): self.show(error)
            }
        }
    }

    func loadAgentPresets() {
        api.listAgentPresets { [weak self] result in
            if case let .success(value) = result { self?.agentPresets = value.presets; self?.agentPresetAuthorable = value.authorable; self?.agentPresetHasDocument = value.hasDocument }
        }
    }

    func loadPluginInventory() {
        pluginInventoryLoading = true
        pluginInventoryError = nil
        api.pluginInventory { [weak self] result in
            guard let self else { return }
            self.pluginInventoryLoading = false
            switch result {
            case let .success(entries): self.pluginInventory = entries
            case let .failure(error): self.pluginInventoryError = error.localizedDescription
            }
        }
    }

    func loadPluginSettings() {
        pluginSettingsLoading = true
        pluginSettingsError = nil
        api.pluginSettings { [weak self] result in
            guard let self else { return }
            self.pluginSettingsLoading = false
            switch result {
            case let .success(snapshot): self.pluginSettings = snapshot
            case let .failure(error): self.pluginSettingsError = error.localizedDescription
            }
        }
    }

    func loadHostSettings() {
        hostSettingsLoading = true
        hostSettingsError = nil
        api.settings { [weak self] result in
            guard let self else { return }
            self.hostSettingsLoading = false
            switch result {
            case let .success(snapshot):
                self.hostSettings = snapshot
                if let preference = snapshot.namespace("ui-theme")?.value("preference") as? String {
                    self.appearance = preference == "light" ? 1 : preference == "dark" ? 2 : 0
                }
            case let .failure(error): self.hostSettingsError = error.localizedDescription
            }
        }
    }

    func setHostSetting(namespace: String, path: [String], value: Any) {
        guard let descriptor = hostSettings?.namespace(namespace), hostSettings?.writable == true else { return }
        api.mutateSettings(ns: namespace, ops: [["op": "set", "path": path, "value": value]],
                           expectedRevision: descriptor.revision) { [weak self] result in
            switch result {
            case .success: self?.loadHostSettings()
            case let .failure(error): self?.show(error); self?.loadHostSettings()
            }
        }
    }

    func openSettingsDocument() {
        guard hostSettings?.hasDocument == true, !settingsDocumentOpening else { return }
        settingsDocumentOpening = true
        api.openSettingsDocument { [weak self] result in
            guard let self else { return }
            self.settingsDocumentOpening = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    var busyEnterMode: String {
        hostSettings?.namespace("ui-conversation")?.value("busyEnter") as? String ?? "queue"
    }

    func savePluginSettings(namespace: String, fields: [String: String], apiKey: String? = nil,
                            completion: @escaping (Bool) -> Void) {
        guard let snapshot = pluginSettings?.namespace(namespace), pluginSettings?.writable == true else {
            completion(false); return
        }
        let numeric = Set(["timeoutMs", "maxOutputBytes", "maxParallelToolCalls", "maxUses"])
        var ops: [[String: Any]] = []
        for (field, raw) in fields {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                if snapshot.isOverridden(field) { ops.append(["op": "unset", "path": [field]]) }
            } else if numeric.contains(field) {
                guard let value = Double(text), value.isFinite else { completion(false); return }
                let stored: Any = value.rounded() == value ? Int(value) : value
                if String(describing: snapshot.value(field) ?? "") != String(describing: stored) {
                    ops.append(["op": "set", "path": [field], "value": stored])
                }
            } else if snapshot.value(field) as? String != text {
                ops.append(["op": "set", "path": [field], "value": text])
            }
        }
        let writeCredential: (@escaping (Bool) -> Void) -> Void = { [weak self] done in
            guard let self else { done(false); return }
            let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { done(true); return }
            let ref = snapshot.value["apiKeyEnv"] as? String ?? "DEEPSEEK_API_KEY"
            self.api.setCredential(ref: ref, value: key) { result in
                switch result { case .success: done(true); case let .failure(error): self.show(error); done(false) }
            }
        }
        let finish: (Bool) -> Void = { [weak self] success in
            if success { self?.loadPluginSettings() }
            completion(success)
        }
        guard !ops.isEmpty else { writeCredential(finish); return }
        api.mutateSettings(ns: namespace, ops: ops, expectedRevision: snapshot.revision) { [weak self] result in
            switch result {
            case .success: writeCredential(finish)
            case let .failure(error): self?.show(error); completion(false)
            }
        }
    }

    func loadCordisInventory() {
        cordisInventoryLoading = true
        cordisInventoryError = nil
        api.cordisInventory { [weak self] result in
            guard let self else { return }
            self.cordisInventoryLoading = false
            switch result {
            case let .success(rows): self.cordisInventory = rows
            case let .failure(error): self.cordisInventoryError = error.localizedDescription
            }
        }
    }

    func stopCordis(_ row: CordisInventoryRow) {
        guard !cordisActionBusy.contains(row.pluginId) else { return }
        cordisActionBusy.insert(row.pluginId); cordisActionErrors[row.pluginId] = nil
        api.cordisStop(agentId: row.agentId, pluginId: row.pluginId) { [weak self] result in
            guard let self else { return }
            self.cordisActionBusy.remove(row.pluginId)
            if case let .failure(error) = result { self.cordisActionErrors[row.pluginId] = error.localizedDescription }
            self.loadCordisInventory()
        }
    }

    func removeCordis(_ row: CordisInventoryRow) {
        guard !cordisActionBusy.contains(row.pluginId) else { return }
        cordisActionBusy.insert(row.pluginId); cordisActionErrors[row.pluginId] = nil
        api.cordisRemove(agentId: row.agentId, pluginId: row.pluginId) { [weak self] result in
            guard let self else { return }
            self.cordisActionBusy.remove(row.pluginId)
            if case let .failure(error) = result { self.cordisActionErrors[row.pluginId] = error.localizedDescription }
            self.loadCordisInventory()
        }
    }

    func cordisReading(for tool: ToolCall) -> String? {
        guard let card = tool.cordis else { return nil }
        switch card {
        case let .define(define):
            guard let pluginId = define.pluginId else { return nil }
            if cordisWasRemoved(pluginId) { return "已移除" }
            return cordisVisibleReading(pluginId: pluginId, packageId: define.packageId)
        case let .run(run):
            guard let pluginId = run.pluginId else { return "待激活" }
            if cordisWasRemoved(pluginId) { return "已移除" }
            if let seq = run.seq, history.contains(where: { item in
                guard case let .tool(other) = item.kind, other.id != tool.id,
                      case let .run(candidate)? = other.cordis else { return false }
                return candidate.state == .ok && candidate.pluginId == pluginId
                    && candidate.packageId == run.packageId && (candidate.seq ?? -1) > seq
            }) { return "已有更新" }
            if let attempt = cordisInventory.first(where: { $0.pluginId == pluginId })?.latestRun,
               attempt.pluginRunId == run.pluginRunId {
                if attempt.status == "awaiting-approval" { return "待审批" }
                if attempt.status == "failed" { return "运行失败" }
            }
            return cordisVisibleReading(pluginId: pluginId, packageId: run.packageId)
        case .action:
            return nil
        }
    }

    func cordisRunMessage(for tool: ToolCall) -> String? {
        guard case let .run(run)? = tool.cordis, let reading = cordisReading(for: tool) else { return nil }
        if reading == "已移除" { return "包已不存在" }
        if reading == "已有更新" { return "已有更新的运行卡片，请查看下方" }
        if reading == "运行失败", let pluginId = run.pluginId,
           let attempt = cordisInventory.first(where: { $0.pluginId == pluginId })?.latestRun,
           attempt.pluginRunId == run.pluginRunId { return attempt.errorMessage }
        return nil
    }

    private func cordisVisibleReading(pluginId: String, packageId: String?) -> String {
        guard let packageId, let row = cordisInventory.first(where: { $0.pluginId == pluginId }),
              row.activePackageId == packageId else { return "待激活" }
        let package = row.packages.first(where: { $0.packageId == packageId })
        // AppKit cannot host the browser Package's React Client half; expose
        // WebUI's honest pre-load reading rather than claiming it is running.
        return package?.hasClientHalf == true ? "Client 待激活" : "运行中"
    }

    private func cordisWasRemoved(_ pluginId: String) -> Bool {
        history.contains { item in
            guard case let .tool(tool) = item.kind, tool.name == "cordis_undefine", tool.state == .ok,
                  case let .action(action)? = tool.cordis else { return false }
            return action.pluginId == pluginId
        }
    }

    func loadModelProviders() {
        modelProvidersLoading = true
        modelProvidersError = nil
        api.modelProviderSettings { [weak self] result in
            guard let self else { return }
            self.modelProvidersLoading = false
            switch result {
            case let .success(value): self.modelProviders = value.rows; self.modelProvidersWritable = value.writable
            case let .failure(error): self.modelProvidersError = error.localizedDescription
            }
        }
    }

    func saveProviderCredential(_ provider: ModelProviderSettings, value: String, completion: @escaping (Bool) -> Void) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, provider.credential?.writable != false, modelProvidersWritable else { completion(false); return }
        let ref = provider.credentialRef
        let writeKey: () -> Void = { [weak self] in
            guard let self else { completion(false); return }
            self.api.setCredential(ref: ref, value: trimmed) { [weak self] result in
                guard let self else { completion(false); return }
                switch result {
                case .success: self.loadModelProviders(); completion(true)
                case let .failure(error): self.show(error); completion(false)
                }
            }
        }
        guard provider.apiKeyRef == nil else { writeKey(); return }
        let op: [String: Any] = ["op": "set", "path": provider.settingsPath + ["apiKeyEnv"], "value": ref]
        api.mutateSettings(ns: provider.settingsNamespace, ops: [op], expectedRevision: provider.revision) { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case .success: writeKey()
            case let .failure(error): self.show(error); completion(false)
            }
        }
    }

    func removeProvider(_ provider: ModelProviderSettings) {
        guard provider.removable, modelProvidersWritable else { return }
        let removeSettings: () -> Void = { [weak self] in
            guard let self else { return }
            self.api.mutateSettings(ns: provider.settingsNamespace,
                                    ops: [["op": "unset", "path": provider.settingsPath]]) { [weak self] result in
                switch result {
                case .success: self?.loadModelProviders()
                case let .failure(error): self?.show(error)
                }
            }
        }
        if provider.apiKeyRef == provider.credentialRef,
           provider.credential?.configured == true, provider.credential?.writable == true {
            api.unsetCredential(ref: provider.credentialRef) { [weak self] result in
                switch result {
                case .success: removeSettings()
                case let .failure(error): self?.show(error)
                }
            }
        } else { removeSettings() }
    }

    func readPreset(_ preset: AgentPresetEntry) {
        api.readAgentPreset(preset.id) { [weak self] result in
            switch result { case let .success(value): self?.agentPresetContent = value.content; case let .failure(error): self?.show(error) }
        }
    }

    func openPreset(_ preset: AgentPresetEntry) {
        api.openAgentPreset(preset.id) { [weak self] result in
            switch result {
            case let .success(value):
                if !value.opened, let path = value.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            case let .failure(error): self?.show(error)
            }
        }
    }

    func copyPreset(_ preset: AgentPresetEntry, to id: String) {
        api.copyAgentPreset(from: preset.id, to: id, name: nil) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) } else { self?.loadAgentPresets() }
        }
    }

    func removePreset(_ preset: AgentPresetEntry) {
        api.removeAgentPreset(preset.id) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) } else { self?.loadAgentPresets() }
        }
    }

    func selectPreset(_ preset: AgentPresetEntry) {
        guard let current, current.blank else { return }
        api.selectAgentPreset(sessionId: current.id, preset: preset.id) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) }
            self?.refresh()
        }
    }

    func loadSubagents(for parent: String) {
        api.listSubagents(parentSessionId: parent) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(value):
                self.subagents[parent] = value.entries
                self.subagentParentAvailable[parent] = value.parentAvailable
                for child in value.entries where !child.isDiagnostic {
                    self.subagentModesById[child.id] = child.mode
                }
            case let .failure(error): self.show(error)
            }
        }
    }

    func openSubagent(_ child: SubagentEntry, parent: String) {
        subagentModesById[child.id] = child.mode
        if let row = sessions.first(where: { $0.id == child.id }) {
            activateSubagent(row, parent: parent, mode: child.mode)
            return
        }
        // A descriptor can reach the catalog one frame before session.list.
        // Refresh once so a visible row never behaves like a dead button.
        api.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(rows):
                self.sessions = rows
                guard let row = rows.first(where: { $0.id == child.id }) else { return }
                self.activateSubagent(row, parent: parent, mode: child.mode)
            case let .failure(error): self.show(error)
            }
        }
    }

    private func activateSubagent(_ row: SessionSummary, parent: String, mode: String) {
        subagentParentId = parent
        currentSubagentMode = mode
        select(row)
    }

    func interruptSubagent(_ child: SubagentEntry, parent: String) {
        guard child.mode == "continuable" else { return }
        api.interruptSubagent(parentSessionId: parent, childSessionId: child.id, mode: child.mode) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) }
            self?.scheduleRefresh()
        }
    }

    func searchSessions(_ query: String) {
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = query.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { sessionSearchHits = []; sessionSearchLoading = false; sessionSearchHasMore = false; return }
        sessionSearchLoading = true
        api.searchSessions(query: String(trimmed.prefix(500))) { [weak self] result in
            guard let self else { return }
            guard generation == self.searchGeneration else { return }
            self.sessionSearchLoading = false
            switch result {
            case let .success(value): self.sessionSearchHits = value.items; self.sessionSearchHasMore = value.hasMore
            case let .failure(error): self.sessionSearchHits = []; self.show(error)
            }
        }
    }

    func sessionSnippet(_ id: String) -> String? {
        sessionSearchHits.first(where: { $0.sessionId == id })?.snippet
    }

    func ancestry(for session: SessionSummary) -> [SessionSummary] {
        var result: [SessionSummary] = []
        var cursor: SessionSummary? = session
        var seen = Set<String>()
        while let row = cursor, seen.insert(row.id).inserted {
            result.insert(row, at: 0)
            cursor = row.parentSessionId.flatMap { parent in sessions.first(where: { $0.id == parent }) }
        }
        return result
    }

    func select(_ session: SessionSummary) {
        let previousID = current?.id
        guard previousID != session.id || (session.parentSessionId != nil && currentSubagentMode == nil) else { return }
        detail = nil
        current = session
        if let parent = session.parentSessionId {
            subagentParentId = parent
            currentSubagentMode = subagentModesById[session.id]
                ?? subagents[parent]?.first(where: { $0.id == session.id })?.mode
                ?? currentSubagentMode
        } else {
            subagentParentId = nil
            currentSubagentMode = nil
        }
        history = []
        trajectory = []
        projections = SessionProjections()
        streamingSteps = [:]
        // Pending interactions are global so the sidebar can signal other
        // sessions, but only the current session's request takes the composer.
        models = []
        currentModel = nil
        commands = []
        feedback = [:]
        load(session)
        loadSubagents(for: session.id)
    }

    /// Workspace owning the current session. Membership is authoritative;
    /// cwd alone must not adopt an ungrouped CLI/TUI session.
    var currentWorkspace: WorkspaceSummary? {
        guard let current else { return nil }
        if let owned = workspaces.first(where: { $0.sessionIds.contains(current.id) }) { return owned }
        // A just-created workspace session can arrive one frame before the
        // workspace membership baseline; only blank sessions use this narrow
        // bridge, never active ungrouped sessions.
        if current.blank, let cwd = current.cwd { return workspaces.first { $0.path == cwd } }
        return nil
    }

    /// Shared New Session action: explicit/current workspace first, then the
    /// most recent registered workspace. Reuse its blank session exactly like
    /// WebUI `connectWorkspace`, rather than minting duplicates on every click.
    func createSession() {
        if let workspace = currentWorkspace ?? workspaces.first {
            createSession(workspace: workspace)
        } else {
            createSession(workspace: nil)
        }
    }

    func createSession(workspace: WorkspaceSummary?) {
        if let workspace,
           let blank = sessions.first(where: {
               $0.blank && $0.cwd == workspace.path
                   && workspace.sessionIds.contains($0.id)
                   && !archivedSessionIds.contains($0.id)
           }) {
            select(blank)
            return
        }
        let cwd = workspace?.path ?? current?.cwd ?? sessions.first?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        isLoading = true
        api.createSession(cwd: workspace == nil ? cwd : nil, workspaceId: workspace?.id, agentPreset: agentPresets.first(where: { $0.isDefault })?.id) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case let .success(id): self.refreshWorkspaces(); self.refreshAndOpen(id)
            case let .failure(error): self.show(error)
            }
        }
    }

    func send(_ text: String, mode: String = "queue") {
        guard let current else { createSession(); return }
        // Host commands are control-plane actions, not user prompts. WebUI
        // intercepts a registered `/name ...` line and sends it through
        // commands.execute so no user bubble or LLM turn is created.
        if draftImages.isEmpty, let name = Self.slashCommandName(in: text),
           commands.contains(where: { $0.name == name }) {
            api.executeCommand(sessionId: current.id, line: text) { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result { self.show(error) }
                self.scheduleRefresh()
            }
            return
        }
        if !text.isEmpty { history.append(ConversationItem(id: "local-\(UUID().uuidString)", kind: .user(text: text, images: []), seq: nil, time: Date())) }
        self.current = current.withRunning(true, blank: false, updatedAt: Date())
        let images = draftImages
        if let parent = subagentParentId, let childMode = currentSubagentMode, childMode == "continuable" {
            api.subagentPrompt(parentSessionId: parent, childSessionId: current.id, mode: childMode, text: text, images: images) { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result { self.showPromptError(error) } else { self.draftImages.removeAll { Set(images.map(\.id)).contains($0.id) } }
                self.scheduleRefresh()
            }
            return
        }
        api.prompt(sessionId: current.id, text: text, images: images, mode: mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // Remove only the images that belonged to this prompt.  New
                // attachments added while the RPC was in flight stay queued.
                let sent = Set(images.map(\.id))
                self.draftImages.removeAll { sent.contains($0.id) }
            case let .failure(error):
                // Keep the rail intact so a failed upload can be retried,
                // matching the WebUI's transient prompt-error behaviour.
                self.showPromptError(error)
            }
            self.scheduleRefresh()
        }
    }

    func addImage(url: URL) {
        guard let type = imageMediaType(url: url) else {
            errorText = "仅支持 PNG、JPG、WebP、GIF 格式的图片"
            return
        }
        guard let data = try? Data(contentsOf: url) else { errorText = "无法读取图片"; return }
        addImages([DraftImageCandidate(data: data, name: url.lastPathComponent, mediaType: type)])
    }

    func addImage(data: Data, name: String, mediaType: String) {
        addImages([DraftImageCandidate(data: data, name: name, mediaType: mediaType)])
    }

    func addImages(_ candidates: [DraftImageCandidate]) {
        guard !candidates.isEmpty, candidates.allSatisfy({ !$0.data.isEmpty }) else { errorText = "无法读取图片"; return }
        if let rejection = imageIntakeRejection(candidates) {
            errorText = rejection
            return
        }
        draftImages.append(contentsOf: candidates.map { candidate in
            DraftImage(id: UUID(), url: URL(fileURLWithPath: "/\(candidate.name)"),
                       mediaType: candidate.mediaType, data: candidate.data)
        })
    }

    func canAddImageCount(_ count: Int = 1) -> Bool {
        guard let limits = projections.imageLimits else { return true }
        return draftImages.count + count <= limits.maxImagesPerMessage
    }

    var imageDropDescription: String? {
        guard let limits = projections.imageLimits else { return nil }
        return "最多 \(limits.maxImagesPerMessage) 张，每张 \(limits.perImageSizeText)"
    }

    func removeImage(_ image: DraftImage) { draftImages.removeAll { $0.id == image.id } }

    func loadImage(_ ref: ImageAttachmentRef, completion: @escaping (Data?) -> Void) {
        guard let sessionId = current?.id else { completion(nil); return }
        api.attachment(sessionId: sessionId, attachmentId: ref.attachmentId) { result in
            DispatchQueue.main.async { completion(try? result.get()) }
        }
    }

    private func imageMediaType(url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"; case "jpg", "jpeg": "image/jpeg"; case "webp": "image/webp"; case "gif": "image/gif"; default: nil
        }
    }

    private func imageIntakeRejection(_ candidates: [DraftImageCandidate]) -> String? {
        guard let limits = projections.imageLimits else { return nil }
        if candidates.contains(where: { !limits.mediaTypes.contains($0.mediaType) }) {
            return "仅支持 PNG、JPG、WebP、GIF 格式的图片"
        }
        if draftImages.count + candidates.count > limits.maxImagesPerMessage {
            return "一条消息最多添加 \(limits.maxImagesPerMessage) 张图片"
        }
        if candidates.contains(where: { $0.data.count > limits.maxImageBytes }) {
            return "单张图片不能超过 \(limits.perImageSizeText)"
        }
        let additionBytes = candidates.reduce(0) { $0 + $1.data.count }
        if draftImages.reduce(0, { $0 + $1.data.count }) + additionBytes > limits.maxMessageImageBytes {
            return "图片总大小超过 \(limits.totalSizeText)，请移除部分图片"
        }
        for candidate in candidates {
            guard let image = NSImage(data: candidate.data) else { return "仅支持 PNG、JPG、WebP、GIF 格式的图片" }
            let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
                ?? Int(image.size.width * image.size.height)
            if pixels > limits.maxImagePixels { return "图片分辨率过大，请压缩后重试" }
        }
        return nil
    }

    func stop() {
        guard let current else { return }
        api.cancel(sessionId: current.id) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) }
            self?.scheduleRefresh()
        }
    }

    func refreshModels() {
        guard let session = current, subagentParentId == nil else { return }
        modelCatalogLoading = true
        modelCatalogError = nil
        api.models(sessionId: session.id) { [weak self] result in
            guard let self, self.current?.id == session.id else { return }
            self.modelCatalogLoading = false
            switch result {
            case let .success(value):
                self.models = value.choices
                self.currentModel = value.current
                self.modelCatalogFailures = value.failures
                self.currentModelRoutable = value.routable
            case let .failure(error):
                self.modelCatalogError = error.localizedDescription
            }
        }
    }

    func chooseModel(_ choice: ModelChoice, completion: ((Bool) -> Void)? = nil) {
        guard let current else { completion?(false); return }
        // WebUI submits the selected provider/model only. The Host/provider
        // applies its default effort; pinning choice.defaultEffort here would
        // turn a default into a user override.
        choose(ModelSelection(provider: choice.provider, model: choice.id, reasoningEffort: nil), in: current.id, completion: completion)
    }

    func chooseEffort(_ effort: String?, completion: ((Bool) -> Void)? = nil) {
        guard let current, let selection = currentModel else { completion?(false); return }
        choose(ModelSelection(provider: selection.provider, model: selection.model, reasoningEffort: effort), in: current.id, completion: completion)
    }

    private func choose(_ selection: ModelSelection, in sessionId: String, completion: ((Bool) -> Void)?) {
        guard !modelSelectionBusy else { completion?(false); return }
        modelSelectionBusy = true
        api.selectModel(sessionId: sessionId, selection: selection) { [weak self] result in
            guard let self else { completion?(false); return }
            self.modelSelectionBusy = false
            guard self.current?.id == sessionId else { completion?(false); return }
            switch result {
            case let .success(selected): self.currentModel = selected; self.currentModelRoutable = true; completion?(true)
            case let .failure(error): self.show(error); completion?(false)
            }
        }
    }

    func choosePermission(_ permission: String, completion: ((Bool) -> Void)? = nil) {
        guard let current, !permissionSelectionBusy else { completion?(false); return }
        let sessionId = current.id
        permissionSelectionBusy = true
        api.setPermission(sessionId: sessionId, permission: permission) { [weak self] result in
            guard let self else { completion?(false); return }
            self.permissionSelectionBusy = false
            guard self.current?.id == sessionId else { completion?(false); return }
            switch result {
            case .success:
                if var value = self.projections.permissions { value.currentValue = permission; self.projections.permissions = value }
                completion?(true)
            case let .failure(error): self.show(error); completion?(false)
            }
            self.scheduleRefresh()
        }
    }

    func exitPlanMode() {
        guard let current, projections.plan?.targetActive == true, !planSelectionBusy else { return }
        let sessionId = current.id
        planSelectionBusy = true
        api.executeCommand(sessionId: sessionId, line: "/plan off") { [weak self] result in
            guard let self else { return }
            self.planSelectionBusy = false
            switch result {
            case .success: self.scheduleRefresh()
            case let .failure(error): self.show(error)
            }
        }
    }

    private static func slashCommandName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let tail = trimmed.dropFirst()
        guard let name = tail.split(whereSeparator: { $0.isWhitespace }).first, !name.isEmpty else { return nil }
        let value = String(name)
        guard value.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil else { return nil }
        return value
    }

    func exportSessionLog() {
        guard let current, !current.blank, !sessionLogExportBusy else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Session log"
        panel.prompt = "下载"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let safeId = current.id.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "session-\(safeId).zip"
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.sessionLogExportBusy = true
            self.api.downloadSessionLog(sessionId: current.id, includeDescendants: true) { [weak self] result in
                guard let self else { return }
                self.sessionLogExportBusy = false
                do {
                    try result.get().write(to: destination, options: .atomic)
                } catch {
                    self.show(error)
                }
            }
        }
    }

    func rename(_ session: SessionSummary, to title: String) {
        api.rename(sessionId: session.id, title: title) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) }
            self?.refresh()
        }
    }

    func rateMessage(messageId: String, rating: String) {
        guard let current else { return }
        let existing = feedback[messageId]
        if let existing, existing.rating == rating {
            api.feedbackDelete(sessionId: current.id, messageId: messageId, version: existing.version) { [weak self] result in
                guard let self else { return }
                switch result { case .success: self.feedback.removeValue(forKey: messageId); case let .failure(error): self.show(error) }
            }
            return
        }
        api.feedbackPut(sessionId: current.id, messageId: messageId, rating: rating, note: existing?.note, ifVersion: existing?.version) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(item): self.feedback[messageId] = item
            case let .failure(error): self.show(error)
            }
        }
    }

    func saveFeedbackNote(messageId: String, note: String, completion: @escaping (Bool) -> Void) {
        guard let current, let existing = feedback[messageId] else { completion(false); return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // The wire rejects blank notes. An empty editor intentionally clears it
        // by replacing the item without a note while retaining the rating.
        api.feedbackPut(sessionId: current.id, messageId: messageId, rating: existing.rating,
                        note: trimmed.isEmpty ? nil : trimmed, ifVersion: existing.version) { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case let .success(item): self.feedback[messageId] = item; completion(true)
            case let .failure(error): self.show(error); self.reloadFeedback(sessionId: current.id); completion(false)
            }
        }
    }

    private func reloadFeedback(sessionId: String) {
        api.feedbackList(sessionId: sessionId) { [weak self] result in
            guard let self, self.current?.id == sessionId else { return }
            if case let .success(items) = result { self.feedback = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) }) }
        }
    }

    func showTool(_ tool: ToolCall) { self.detail = ToolDetail(tool: tool) }

    func openToolPath(_ path: String) {
        let resolved: String
        if path.hasPrefix("/") { resolved = URL(fileURLWithPath: path).standardized.path }
        else if let cwd = current?.cwd { resolved = URL(fileURLWithPath: cwd).appendingPathComponent(path).standardized.path }
        else { resolved = path }
        api.openPath(resolved) { [weak self] result in
            if case let .failure(error) = result { self?.show(error) }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySessionID(_ session: SessionSummary) { copy(session.id) }

    func openWorkspace(_ session: SessionSummary) {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    func revealWorkspace(_ session: SessionSummary) {
        guard let cwd = session.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    func branch(at seq: Int?) {
        guard let seq else { return }
        branch(session: current, at: seq)
    }

    func branch(session: SessionSummary?, at seq: Int?) {
        guard let session else { return }
        isLoading = true
        api.fork(sessionId: session.id, atSeq: seq) { [weak self] result in
            guard let self else { return }
            self.isLoading = false
            switch result {
            case let .success(id): self.refreshAndOpen(id)
            case let .failure(error): self.show(error)
            }
        }
    }

    /// WebUI exposes the branch action on every completed turn tail but only
    /// enables the latest chat tail of an idle session.
    func branchAvailable(at seq: Int?) -> Bool {
        guard let seq, current?.running != true else { return false }
        // WebUI compares against the latest completed chat turn tail. A
        // later notice/projection event must not make that tail unavailable.
        let latestTail = history.compactMap { item -> Int? in
            if case .assistantActions = item.kind { return item.seq }
            return nil
        }.max()
        return latestTail == seq
    }

    func runningSubagentCount(for session: SessionSummary) -> Int {
        subagentCounts(for: session).running
    }

    func subagentCounts(for session: SessionSummary) -> (total: Int, running: Int) {
        var childrenByParent: [String: [SessionSummary]] = [:]
        for row in sessions where row.origin == "subagent" {
            if let parent = row.parentSessionId { childrenByParent[parent, default: []].append(row) }
        }
        var visited = Set<String>()
        func count(_ parent: String) -> (total: Int, running: Int) {
            guard visited.insert(parent).inserted else { return (0, 0) }
            let children = childrenByParent[parent] ?? []
            return children.reduce(into: (total: 0, running: 0)) { result, child in
                result.total += 1
                if child.running { result.running += 1 }
                let nested = count(child.id)
                result.total += nested.total
                result.running += nested.running
            }
        }
        return count(session.id)
    }

    func answerApproval(_ request: ApprovalRequest, outcome: String) {
        interactionBusy = true
        api.respond(rpcId: request.rpcId, result: ["ok": true, "value": [
            "sessionId": request.sessionId, "approvalId": request.approvalId, "outcome": outcome,
        ]]) { [weak self] result in
            guard let self else { return }
            self.interactionBusy = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    func answerQuestions(_ request: QuestionRequest, answers: [[String: Any]]) {
        interactionBusy = true
        api.respond(rpcId: request.rpcId, result: ["ok": true, "value": [
            "sessionId": request.sessionId, "answer": ["answers": answers],
        ]]) { [weak self] result in
            guard let self else { return }
            self.interactionBusy = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    func cancelQuestions(_ request: QuestionRequest) {
        interactionBusy = true
        api.respond(rpcId: request.rpcId, result: ["ok": false, "error": [
            "code": "cancelled", "message": "the user closed this question request", "details": [:],
        ]]) { [weak self] result in
            guard let self else { return }
            self.interactionBusy = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    func updateQueue(_ item: QueuedMessage, action: [String: Any]) {
        guard let current else { return }
        dockBusy = true
        api.updateQueue(sessionId: current.id, itemId: item.id, action: action) { [weak self] result in
            guard let self else { return }
            self.dockBusy = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    func mutateGoal(_ method: String, objective: String? = nil) {
        guard let current, let goal = projections.goal else { return }
        dockBusy = true
        api.mutateGoal(method: method, sessionId: current.id, goal: goal, objective: objective) { [weak self] result in
            guard let self else { return }
            self.dockBusy = false
            if case let .failure(error) = result { self.show(error) }
        }
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(selectNewest: false) }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func handleMuxFrame(_ payload: [String: Any]) {
        guard let frameType = payload["type"] as? String else { return }
        if frameType.hasPrefix("cordis/") {
            loadCordisInventory()
            return
        }
        guard let sessionId = payload["sessionId"] as? String else { return }
        if frameType == "approval/requested" {
            guard let rpcId = payload["_rpcId"] as? String,
                  let approvalId = payload["approvalId"] as? String,
                  let toolName = payload["toolName"] as? String else { return }
            upsertInteraction(.approval(ApprovalRequest(rpcId: rpcId, sessionId: sessionId,
                approvalId: approvalId, toolName: toolName, callId: payload["callId"] as? String,
                reason: payload["reason"] as? String)))
            return
        }
        if frameType == "question/requested" {
            guard let rpcId = payload["_rpcId"] as? String else { return }
            let questions = payload.array("questions").compactMap(parseQuestion)
            upsertInteraction(.question(QuestionRequest(rpcId: rpcId, sessionId: sessionId, questions: questions)))
            return
        }
        if frameType == "approval/resolved", let approvalId = payload["approvalId"] as? String {
            interactions.removeAll { if case let .approval(value) = $0 { return value.approvalId == approvalId }; return false }
            return
        }
        if frameType == "question/resolved", let questionRpcId = payload["questionRpcId"] as? String {
            interactions.removeAll { if case let .question(value) = $0 { return value.rpcId == questionRpcId }; return false }
            return
        }
        if frameType == "session/queue" {
            queues[sessionId] = HarnessAPI.parseQueue(payload.array("items"))
            return
        }
        if frameType == "session/jobs" {
            jobs[sessionId] = payload.array("jobs").compactMap { raw in
                guard let id = raw["id"] as? String, let kind = raw["kind"] as? String,
                      let label = raw["label"] as? String, let status = raw["status"] as? String else { return nil }
                let started = raw.double("startedAt"), finished = raw.double("finishedAt")
                return BackgroundJob(id: id, kind: kind, label: label, status: status, detail: raw["detail"] as? String,
                    startedAt: Date(timeIntervalSince1970: started / 1000),
                    finishedAt: finished > 0 ? Date(timeIntervalSince1970: finished / 1000) : nil)
            }
            return
        }
        if frameType == "session/projection" {
            if sessionId == current?.id, payload.int("seq") >= projections.asOfSeq,
               let key = payload["key"] as? String {
                applyProjection(key: key, value: payload["value"], seq: payload.int("seq"))
            }
            return
        }
        guard frameType == "session/event" else { return }
        guard sessionId == current?.id else {
            // Another session's token stream must not repeatedly reload the
            // open 40MB history. Host status/projection frames separately
            // refresh the sidebar state.
            if let otherEvent = payload.dictionary("event"),
               ["turn/start", "turn/end", "user/message"].contains(otherEvent["type"] as? String ?? "") {
                scheduleRefresh()
            }
            return
        }
        guard let event = payload.dictionary("event"), let type = event["type"] as? String else {
            scheduleRefresh()
            return
        }
        let data = event.dictionary("data") ?? [:]
        let turn = data.int("turn"), step = data.int("step")
        let key = "\(turn):\(step)"
        switch type {
        case "assistant/chunk":
            guard let chunk = data.dictionary("chunk") else { return }
            var accumulator = streamingSteps[key] ?? StreamingAssistantAccumulator(turn: turn, step: step)
            let milliseconds = event.double("time")
            let time = milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
            guard accumulator.push(chunk: chunk, seq: event.int("seq"), time: time) else { return }
            streamingSteps[key] = accumulator
            scheduleStreamingRender(key)
        case "llm/retry":
            if var accumulator = streamingSteps[key] {
                accumulator.resetForRetry()
                streamingSteps[key] = accumulator
                replaceStreamingItems(accumulator, running: true)
            }
        case "assistant/message":
            var entry: [String: Any] = ["event": event]
            if let view = payload["view"] { entry["view"] = view }
            let settled = HarnessAPI.parseHistory([entry]).filter { !isToolItem($0) }
            history.removeAll { $0.stepKey == key && !isToolItem($0) }
            history.append(contentsOf: settled)
            streamingSteps.removeValue(forKey: key)
        case "step/end", "turn/end":
            if let accumulator = streamingSteps[key] { replaceStreamingItems(accumulator, running: false) }
            scheduleRefresh()
        default:
            scheduleRefresh()
        }
    }

    private func upsertInteraction(_ interaction: PendingInteraction) {
        interactions.removeAll { $0.id == interaction.id }
        interactions.append(interaction)
    }

    private func parseQuestion(_ raw: [String: Any]) -> QuestionItem? {
        guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
        let options = raw.array("options").compactMap { option -> QuestionOption? in
            guard let label = option["label"] as? String else { return nil }
            return QuestionOption(label: label, description: option["description"] as? String)
        }
        let intent = raw.dictionary("intent").flatMap { value -> QuestionIntent? in
            guard let kind = value["kind"] as? String else { return nil }
            return QuestionIntent(kind: kind, approve: value["approve"] as? String)
        }
        return QuestionItem(id: id, question: question, detail: raw["detail"] as? String,
            header: raw["header"] as? String, options: options,
            multiSelect: raw["multiSelect"] as? Bool ?? false, intent: intent)
    }

    private func replaceStreamingItems(_ accumulator: StreamingAssistantAccumulator, running: Bool) {
        history.removeAll { $0.stepKey == accumulator.key && !isToolItem($0) }
        history.append(contentsOf: accumulator.items(running: running))
    }

    private func scheduleStreamingRender(_ key: String) {
        pendingStreamKeys.insert(key)
        guard streamingRenderWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let keys = self.pendingStreamKeys
            self.pendingStreamKeys.removeAll(keepingCapacity: true)
            self.streamingRenderWorkItem = nil
            for key in keys {
                if let accumulator = self.streamingSteps[key] { self.replaceStreamingItems(accumulator, running: true) }
            }
        }
        streamingRenderWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: work)
    }

    private func isToolItem(_ item: ConversationItem) -> Bool {
        if case .tool = item.kind { return true }
        return false
    }

    private func applyProjection(key: String, value: Any?, seq: Int) {
        projections.asOfSeq = seq
        if key == "todos" {
            let raw = value as? [[String: Any]] ?? []
            projections.todos = raw.compactMap {
                guard let content = $0["content"] as? String, let status = $0["status"] as? String else { return nil }
                return TodoItem(content: content, status: status)
            }
        } else if key == "goal" {
            let container = value as? [String: Any]
            let raw = container?.dictionary("goal") ?? container
            if let raw, let id = raw["id"] as? String, let objective = raw["objective"] as? String,
               let phase = raw["phase"] as? String {
                projections.goal = GoalSnapshot(id: id, revision: raw.int("revision"), objective: objective,
                    phase: phase, blockedReason: raw.dictionary("blockedReason")?["message"] as? String,
                    maxGoalRounds: raw.int("maxGoalRounds"))
            } else { projections.goal = nil }
        } else if key == "plan" {
            guard let raw = value as? [String: Any] else { projections.plan = nil; return }
            projections.plan = PlanModeSnapshot(active: raw["active"] as? Bool ?? false,
                                                pending: raw["pending"] as? Bool ?? false)
        } else if key == "permissions" {
            guard let raw = value as? [String: Any], let current = raw["currentValue"] as? String else {
                projections.permissions = nil
                return
            }
            let options = raw.array("options").compactMap { row -> PermissionOption? in
                guard let id = row["value"] as? String, id != "custom" else { return nil }
                return PermissionOption(value: id, name: row["name"] as? String ?? id,
                    description: row["description"] as? String)
            }
            projections.permissions = PermissionSelectValue(options: options, currentValue: current)
        } else if key == "imageLimits" {
            projections.imageLimits = ImageAttachmentLimits(json: value as? [String: Any])
        } else if key == "tokenUsage" {
            projections.tokenUsage = (value as? [String: Any]).map(TokenUsage.init)
        } else if key == "sessionStats" {
            projections.sessionStats = (value as? [String: Any]).map(SessionStats.init)
        }
    }

    private func refresh(selectNewest: Bool) {
        refreshWorkspaces()
        loadCordisInventory()
        api.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions):
                self.connectionText = "已连接"
                self.sessions = sessions.filter { !self.archivedSessionIds.contains($0.id) }
                if let id = self.current?.id, let updated = sessions.first(where: { $0.id == id }) {
                    self.current = updated
                } else if selectNewest {
                    if self.current?.id != sessions.first?.id { self.detail = nil }
                    self.current = sessions.first
                }
                if let current = self.current { self.load(current) }
            case let .failure(error):
                self.connectionText = "连接失败"
                self.show(error)
            }
        }
    }

    private func load(_ session: SessionSummary) {
        isLoading = true
        let group = DispatchGroup()
        var nextHistory = history
        var nextTrajectory = trajectory
        var nextModels = models
        var nextSelection = currentModel
        var nextCommands = commands
        var nextProjections = projections
        var loadError: Error?
        group.enter()
        let historyDone: (Result<HistorySnapshot, Error>) -> Void = { result in
            switch result { case let .success(value): nextHistory = value.items; nextTrajectory = value.trajectory; nextProjections = value.projections; case let .failure(error): loadError = error }
            group.leave()
        }
        if let parent = subagentParentId, let mode = currentSubagentMode {
            api.subagentHistory(parentSessionId: parent, childSessionId: session.id, mode: mode, completion: historyDone)
        } else {
            api.history(sessionId: session.id, completion: historyDone)
        }
        group.enter()
        api.models(sessionId: session.id) { result in
            if case let .success(value) = result {
                nextModels = value.choices; nextSelection = value.current
                self.modelCatalogFailures = value.failures; self.currentModelRoutable = value.routable
            }
            group.leave()
        }
        group.enter()
        api.commands(sessionId: session.id) { result in
            if case let .success(value) = result { nextCommands = value }
            group.leave()
        }
        var nextFeedback = feedback
        group.enter()
        api.feedbackList(sessionId: session.id) { result in
            if case let .success(items) = result { nextFeedback = Dictionary(uniqueKeysWithValues: items.map { ($0.messageId, $0) }) }
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.current?.id == session.id else { return }
            self.isLoading = false
            self.history = nextHistory
            self.trajectory = nextTrajectory
            self.models = nextModels
            self.currentModel = nextSelection
            self.commands = nextCommands
            self.projections = nextProjections
            self.feedback = nextFeedback
            if let loadError { self.show(loadError) }
        }
    }

    private func refreshAndOpen(_ id: String) {
        api.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(rows):
                self.sessions = rows
                if let session = rows.first(where: { $0.id == id }) {
                    self.detail = nil
                    self.current = session
                    self.history = []
                    self.load(session)
                }
            case let .failure(error): self.show(error)
            }
        }
    }

    private func show(_ error: Error) { errorText = error.localizedDescription }

    private func showPromptError(_ error: Error) {
        guard let apiError = error as? APIError,
              apiError.serverCode == "attachment-error",
              let reason = apiError.serverReason else {
            show(error)
            return
        }
        errorText = attachmentErrorText(reason: reason, limits: projections.imageLimits)
    }
}
