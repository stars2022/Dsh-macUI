import Foundation

@MainActor
final class MobileAppModel: ObservableObject {
    @Published var sessions: [MobileSession] = []
    @Published var workspaces: [MobileWorkspace] = []
    @Published var selectedSessionID: String?
    @Published var messages: [MobileMessage] = []
    @Published var draft = ""
    @Published var loading = false
    @Published var sending = false
    @Published var status = "正在连接…"
    @Published var errorMessage: String?
    @Published var showingSettings = false
    @Published var models: [MobileModelChoice] = []
    @Published var currentModel: MobileModelSelection?
    @Published var modelCatalogLoading = false
    @Published var modelSelectionBusy = false
    @Published var permissionSelectionBusy = false
    @Published var goalBusy = false
    @Published var planSelectionBusy = false
    @Published var workspaceSelectionBusy = false
    @Published var showingNewSession = false
    @Published var subagents: [String: [MobileSubagentEntry]] = [:]
    @Published var subagentStack: [MobileSubagentNavigation] = []
    @Published var subagentParentAvailable: [String: Bool] = [:]
    @Published var jobs: [String: [MobileBackgroundJob]] = [:]
    @Published var queues: [String: [MobileQueuedMessage]] = [:]
    @Published var approvals: [MobileApprovalRequest] = []
    @Published var draftAttachments: [MobileDraftAttachment] = []
    @Published var reconnecting = false
    @Published var interactionBusy = false
    let profiles = ServerProfileStore()
    private let eventStream = MobileEventStream()
    private var liveRefreshTask: Task<Void, Never>?
    private var relayRefreshTask: Task<Void, Never>?

    var selectedSession: MobileSession? { sessions.first { $0.id == selectedSessionID } }
    var activeConversationID: String? { subagentStack.last?.entry.id ?? selectedSessionID }
    var conversationTitle: String { subagentStack.last?.entry.displayName ?? selectedSession?.title ?? "DeepSeek Harness" }
    var currentJobs: [MobileBackgroundJob] {
        guard let id = activeConversationID else { return [] }
        return (jobs[id] ?? []).sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive { return $0.startedAt < $1.startedAt }
            return ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt)
        }
    }
    var currentQueue: [MobileQueuedMessage] {
        guard let id = activeConversationID else { return [] }
        return (queues[id] ?? []).filter { $0.placement == "queued" }
    }
    var currentApproval: MobileApprovalRequest? {
        guard let id = activeConversationID else { return nil }
        return approvals.first { $0.sessionID == id }
    }
    var isConversationRunning: Bool {
        if let child = subagentStack.last { return child.entry.activity == "running" }
        return selectedSession?.running == true
    }
    var currentWorkspace: MobileWorkspace? {
        guard let selectedSession else { return workspaces.first }
        if let owner = workspaces.first(where: { $0.sessionIDs.contains(selectedSession.id) }) { return owner }
        if selectedSession.blank, let cwd = selectedSession.cwd {
            return workspaces.first(where: { $0.path == cwd })
        }
        return nil
    }

    func start() async {
        configureLiveUpdates()
        await refresh()
    }

    func setSceneActive(_ active: Bool) {
        if active { configureLiveUpdates() }
        else {
            eventStream.disconnect()
            relayRefreshTask?.cancel()
            relayRefreshTask = nil
        }
    }

    func select(_ session: MobileSession) async {
        subagentStack = []
        selectedSessionID = session.id
        await loadHistory(session.id)
        await loadModels(session.id)
        await loadSubagents(parentID: session.id)
    }

    func refresh(reportErrors: Bool = true) async {
        loading = true
        defer { loading = false }
        do {
            let client = try transport()
            let result = try await client.call("session.list", payload: [:])
            sessions = (result["items"] as? [[String: Any]] ?? []).compactMap(MobileSession.init).sorted { $0.updatedAt > $1.updatedAt }
            if let workspaceResult = try? await client.call("workspace.list", payload: [:]) {
                workspaces = (workspaceResult["items"] as? [[String: Any]]
                              ?? workspaceResult["workspaces"] as? [[String: Any]]
                              ?? []).compactMap(MobileWorkspace.init)
            }
            status = "已连接 · \(profiles.selected.name)"
            reconnecting = false
            if selectedSessionID == nil, let first = sessions.first { await select(first) }
            else if let selectedSessionID {
                if let child = subagentStack.last {
                    await loadSubagentHistory(parentID: child.parentID, entry: child.entry)
                } else {
                    await loadHistory(selectedSessionID)
                }
                await loadModels(selectedSessionID)
            }
        } catch {
            if reportErrors { show(error) }
            else { status = "正在重新连接…"; reconnecting = true }
        }
    }

    func createSession(workspaceID: String? = nil, ungrouped: Bool = false) async {
        guard !workspaceSelectionBusy else { return }
        workspaceSelectionBusy = true
        defer { workspaceSelectionBusy = false }
        do {
            var payload: [String: Any] = [:]
            if let workspaceID {
                if let workspace = workspaces.first(where: { $0.id == workspaceID }),
                   let reusable = sessions.first(where: {
                       $0.blank && $0.cwd == workspace.path && workspace.sessionIDs.contains($0.id)
                   }) {
                    await select(reusable)
                    showingNewSession = false
                    return
                }
                payload["workspaceId"] = workspaceID
            } else if ungrouped {
                if let cwd = selectedSession?.cwd ?? sessions.first?.cwd { payload["cwd"] = cwd }
            } else if let selectedSessionID,
               let workspace = workspaces.first(where: { $0.sessionIDs.contains(selectedSessionID) }) {
                payload["workspaceId"] = workspace.id
            } else if let workspace = workspaces.first {
                payload["workspaceId"] = workspace.id
            } else if let cwd = selectedSession?.cwd ?? sessions.first?.cwd {
                payload["cwd"] = cwd
            }
            let result = try await transport().call("session.create", payload: payload)
            guard let id = result["sessionId"] as? String else { throw TransportError.invalidResponse }
            selectedSessionID = id
            showingNewSession = false
            await refresh()
        } catch { show(error) }
    }

    @discardableResult
    func createWorkspace(path: String) async -> MobileWorkspace? {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !workspaceSelectionBusy else { return nil }
        workspaceSelectionBusy = true
        defer { workspaceSelectionBusy = false }
        do {
            let result = try await transport().call("workspace.create", payload: ["path": cleaned])
            guard let row = result["workspace"] as? [String: Any],
                  let workspace = MobileWorkspace(json: row) else { throw TransportError.invalidResponse }
            workspaces.removeAll { $0.id == workspace.id }
            workspaces.insert(workspace, at: 0)
            return workspace
        } catch {
            show(error)
            return nil
        }
    }

    func mutateGoal(_ method: String, objective: String? = nil) async {
        guard let sessionID = selectedSessionID, let goal = selectedSession?.goal, !goalBusy else { return }
        goalBusy = true
        defer { goalBusy = false }
        do {
            var payload: [String: Any] = [
                "sessionId": sessionID,
                "ref": ["id": goal.id, "revision": goal.revision],
            ]
            if let objective { payload["objective"] = objective }
            _ = try await transport().call(method, payload: payload)
            await refresh()
        } catch { show(error) }
    }

    func setPlanMode(_ active: Bool) async {
        guard let sessionID = selectedSessionID, !planSelectionBusy else { return }
        planSelectionBusy = true
        defer { planSelectionBusy = false }
        do {
            _ = try await transport().call("commands/execute", payload: [
                "args": ["agentId": sessionID, "line": active ? "/plan on" : "/plan off"],
            ])
            await refresh()
        } catch { show(error) }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !draftAttachments.isEmpty), let sessionID = selectedSessionID else { return }
        let attachments = draftAttachments
        draft = ""
        sending = true
        if !text.isEmpty { messages.append(MobileMessage(id: "local-\(UUID())", role: .user, text: text, time: Date())) }
        defer { sending = false }
        do {
            var content = attachments.compactMap { $0.promptBlock() }
            if !text.isEmpty { content.append(["type": "text", "text": text]) }
            let payload: [String: Any]
            let method: String
            if let child = subagentStack.last {
                guard child.entry.mode == "continuable",
                      subagentParentAvailable[child.parentID] == true else {
                    throw TransportError.remote("这个子代理记录当前只读")
                }
                method = "subagent.prompt"
                payload = ["parentSessionId": child.parentID, "childSessionId": child.entry.id,
                           "mode": child.entry.mode, "content": content,
                           "clientTimeZone": TimeZone.current.identifier]
            } else {
                method = "session.prompt"
                payload = ["sessionId": sessionID, "mode": "queue", "content": content,
                           "clientTimeZone": TimeZone.current.identifier]
            }
            _ = try await transport().call(method, payload: payload)
            let sentIDs = Set(attachments.map(\.id))
            draftAttachments.removeAll { sentIDs.contains($0.id) }
            if let child = subagentStack.last {
                await loadSubagentHistory(parentID: child.parentID, entry: child.entry, reportErrors: false)
                await loadSubagents(parentID: child.parentID)
                return
            }
            var observedRunning = false
            for tick in 0..<1_200 {
                let history = await loadHistory(activeConversationID ?? sessionID, reportErrors: false, matchingPrompt: text)
                if history.hasOpenTurn { observedRunning = true }
                if tick.isMultiple(of: 2), let running = await refreshSessionRunning(sessionID) {
                    observedRunning = observedRunning || running
                    if observedRunning && !running && !history.hasOpenTurn { break }
                }
                if history.promptCompleted { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            await refresh()
        } catch {
            draft = text
            show(error)
        }
    }

    func reconnect() async {
        eventStream.disconnect()
        relayRefreshTask?.cancel()
        selectedSessionID = nil
        subagentStack = []
        messages = []
        models = []
        currentModel = nil
        status = "正在连接…"
        configureLiveUpdates()
        await refresh()
    }

    func loadSubagents(parentID: String) async {
        do {
            let result = try await transport().call("subagent.list", payload: ["parentSessionId": parentID])
            subagents[parentID] = (result["entries"] as? [[String: Any]] ?? []).compactMap(MobileSubagentEntry.init)
            subagentParentAvailable[parentID] = result["parentAvailable"] as? Bool ?? false
        } catch {
            // Subagents are optional on older Hosts; keep the rest of the conversation usable.
        }
    }

    func openSubagent(_ entry: MobileSubagentEntry, parentID: String) async {
        guard !entry.isDiagnostic else { return }
        subagentStack.append(MobileSubagentNavigation(parentID: parentID, entry: entry))
        await loadSubagentHistory(parentID: parentID, entry: entry)
        await loadSubagents(parentID: entry.id)
    }

    func leaveSubagent() async {
        guard !subagentStack.isEmpty else { return }
        subagentStack.removeLast()
        if let parent = subagentStack.last {
            await loadSubagentHistory(parentID: parent.parentID, entry: parent.entry)
        } else if let selectedSessionID {
            await loadHistory(selectedSessionID)
        }
    }

    func interruptSubagent(_ entry: MobileSubagentEntry, parentID: String) async {
        do {
            _ = try await transport().call("subagent.interrupt", payload: [
                "parentSessionId": parentID, "childSessionId": entry.id, "mode": entry.mode,
            ])
            await loadSubagents(parentID: parentID)
        } catch { show(error) }
    }

    func stopCurrentConversation() async {
        do {
            if let child = subagentStack.last {
                try await interruptSubagentThrowing(child.entry, parentID: child.parentID)
                await loadSubagents(parentID: child.parentID)
            } else if let selectedSessionID {
                _ = try await transport().call("session.cancel", payload: ["sessionId": selectedSessionID])
                await refresh(reportErrors: false)
            }
        } catch { show(error) }
    }

    func answerApproval(_ request: MobileApprovalRequest, outcome: String) async {
        guard !interactionBusy else { return }
        interactionBusy = true
        defer { interactionBusy = false }
        do {
            try await transport().respond(rpcID: request.rpcID, result: ["ok": true, "value": [
                "sessionId": request.sessionID,
                "approvalId": request.approvalID,
                "outcome": outcome,
            ]])
        } catch { show(error) }
    }

    func updateQueue(_ item: MobileQueuedMessage, action: [String: Any]) async {
        guard let sessionID = selectedSessionID else { return }
        do {
            _ = try await transport().call("session.updateQueue", payload: [
                "sessionId": sessionID, "itemId": item.id, "action": action,
            ])
        } catch { show(error) }
    }

    private func interruptSubagentThrowing(_ entry: MobileSubagentEntry, parentID: String) async throws {
        _ = try await transport().call("subagent.interrupt", payload: [
            "parentSessionId": parentID, "childSessionId": entry.id, "mode": entry.mode,
        ])
    }

    func addImage(data: Data, name: String, mediaType: String) {
        guard !data.isEmpty else { return }
        guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mediaType) else {
            errorMessage = "仅支持 PNG、JPG、WebP、GIF 图片"
            return
        }
        guard data.count <= 20 * 1_024 * 1_024 else { errorMessage = "单张图片不能超过 20 MB"; return }
        draftAttachments.append(MobileDraftAttachment(id: UUID(), kind: .image, name: name,
                                                       mediaType: mediaType, data: data))
    }

    func addTextFile(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { errorMessage = "无法读取文件"; return }
        guard data.count <= 1_024 * 1_024 else { errorMessage = "文本文件不能超过 1 MB"; return }
        guard String(data: data, encoding: .utf8) != nil else {
            errorMessage = "当前 Host 只支持图片和 UTF-8 文本/代码文件，无法发送这个二进制文件"
            return
        }
        draftAttachments.append(MobileDraftAttachment(id: UUID(), kind: .textFile,
            name: url.lastPathComponent, mediaType: Self.textMediaType(for: url), data: data))
    }

    func removeAttachment(_ attachment: MobileDraftAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
    }

    func chooseModel(_ choice: MobileModelChoice) async {
        guard let sessionID = selectedSessionID, !modelSelectionBusy else { return }
        await selectModel(sessionID: sessionID, provider: choice.provider, model: choice.id, effort: nil)
    }

    func chooseEffort(_ effort: String?) async {
        guard let sessionID = selectedSessionID, let currentModel, !modelSelectionBusy else { return }
        await selectModel(sessionID: sessionID, provider: currentModel.provider,
                          model: currentModel.model, effort: effort)
    }

    func choosePermission(_ permission: String) async {
        guard let sessionID = selectedSessionID, !permissionSelectionBusy else { return }
        permissionSelectionBusy = true
        defer { permissionSelectionBusy = false }
        do {
            _ = try await transport().call("commands/execute", payload: [
                "args": ["agentId": sessionID, "line": "/permission \(permission)"],
            ])
            await refresh()
        } catch { show(error) }
    }

    private func transport() throws -> any HarnessTransport {
        let profile = profiles.selected
        if profile.kind == .localHost { return DirectHarnessTransport(baseURL: profile.baseURL) }
        guard let credential = try KeychainStore.credential(profileID: profile.id) else { throw TransportError.notPaired }
        return RemoteRelayTransport(baseURL: profile.baseURL, credential: credential)
    }

    private func configureLiveUpdates() {
        eventStream.disconnect()
        relayRefreshTask?.cancel()
        relayRefreshTask = nil
        approvals = []
        let profile = profiles.selected
        if profile.kind == .localHost {
            eventStream.onConnectionState = { [weak self] connected in
                guard let self else { return }
                self.reconnecting = !connected
                self.status = connected ? "已连接 · \(self.profiles.selected.name)" : "正在重新连接…"
                if connected { Task { await self.refresh(reportErrors: false) } }
            }
            eventStream.onFrame = { [weak self] frame in self?.handleMuxFrame(frame) }
            eventStream.connect(baseURL: profile.baseURL)
        } else {
            // Relay transport is request/response based, so a quiet refresh
            // loop supplies the same self-healing behaviour without alerts.
            relayRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh(reportErrors: false)
                }
            }
        }
    }

    private func handleMuxFrame(_ payload: [String: Any]) {
        let type = payload["type"] as? String ?? ""
        let sessionID = payload["sessionId"] as? String ?? ""
        if type == "approval/requested" {
            guard let rpcID = payload["_rpcId"] as? String,
                  let approvalID = payload["approvalId"] as? String,
                  let toolName = payload["toolName"] as? String else { return }
            approvals.removeAll { $0.approvalID == approvalID }
            approvals.append(MobileApprovalRequest(rpcID: rpcID, sessionID: sessionID,
                approvalID: approvalID, toolName: toolName,
                callID: payload["callId"] as? String, reason: payload["reason"] as? String))
            return
        }
        if type == "approval/resolved", let approvalID = payload["approvalId"] as? String {
            approvals.removeAll { $0.approvalID == approvalID }
            return
        }
        if type == "session/jobs" {
            jobs[sessionID] = (payload["jobs"] as? [[String: Any]] ?? []).compactMap(MobileBackgroundJob.init)
            return
        }
        if type == "session/queue" {
            queues[sessionID] = (payload["items"] as? [[String: Any]] ?? []).compactMap(MobileQueuedMessage.init)
            return
        }
        if type == "session/projection" || type == "session/status" {
            Task { [weak self] in await self?.refresh(reportErrors: false) }
            return
        }
        if type == "session/event" {
            liveRefreshTask?.cancel()
            liveRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                if sessionID == self.activeConversationID {
                    if let child = self.subagentStack.last {
                        await self.loadSubagentHistory(parentID: child.parentID, entry: child.entry, reportErrors: false)
                    } else if let selectedSessionID = self.selectedSessionID {
                        await self.loadHistory(selectedSessionID, reportErrors: false)
                    }
                }
                if let rootID = self.selectedSessionID { await self.loadSubagents(parentID: rootID) }
            }
        }
    }

    @discardableResult
    private func loadSubagentHistory(parentID: String, entry: MobileSubagentEntry,
                                     reportErrors: Bool = true) async -> HistoryPollState {
        do {
            let result = try await transport().call("subagent.history", payload: [
                "parentSessionId": parentID, "childSessionId": entry.id,
                "mode": entry.mode, "maxMessages": 120,
            ])
            let events = result["events"] as? [[String: Any]] ?? []
            let projection = await Task.detached(priority: .userInitiated) {
                (Self.parseMessages(events), Self.historyState(events, matchingPrompt: nil))
            }.value
            if subagentStack.last?.entry.id == entry.id { messages = projection.0 }
            return projection.1
        } catch {
            if reportErrors { show(error) }
            return .empty
        }
    }

    private static func textMediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "md", "markdown": return "text/markdown"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "csv": return "text/csv"
        case "xml": return "application/xml"
        default: return "text/plain"
        }
    }

    @discardableResult
    private func loadHistory(_ sessionID: String, reportErrors: Bool = true,
                             matchingPrompt: String? = nil) async -> HistoryPollState {
        do {
            let result = try await transport().call("session.history", payload: ["sessionId": sessionID, "maxMessages": 120])
            let entries = result["events"] as? [[String: Any]] ?? []
            let projection = await Task.detached(priority: .userInitiated) {
                (Self.parseMessages(entries), Self.historyState(entries, matchingPrompt: matchingPrompt))
            }.value
            if selectedSessionID == sessionID { messages = projection.0 }
            return projection.1
        } catch {
            if reportErrors { show(error) }
            return .empty
        }
    }

    private func refreshSessionRunning(_ sessionID: String) async -> Bool? {
        do {
            let result = try await transport().call("session.list", payload: [:])
            let latest = (result["items"] as? [[String: Any]] ?? [])
                .compactMap(MobileSession.init)
                .sorted { $0.updatedAt > $1.updatedAt }
            sessions = latest
            return latest.first(where: { $0.id == sessionID })?.running
        } catch {
            return nil
        }
    }

    private func loadModels(_ sessionID: String) async {
        modelCatalogLoading = true
        defer { modelCatalogLoading = false }
        do {
            let result = try await transport().call("session.models", payload: ["sessionId": sessionID])
            if let selected = result["current"] as? [String: Any],
               let provider = selected["provider"] as? String,
               let model = selected["model"] as? String {
                currentModel = MobileModelSelection(provider: provider, model: model,
                    reasoningEffort: selected["reasoningEffort"] as? String)
            }
            models = (result["groups"] as? [[String: Any]] ?? []).flatMap { group -> [MobileModelChoice] in
                guard let provider = group["id"] as? String else { return [] }
                let providerName = group["name"] as? String ?? provider
                return (group["models"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? String else { return nil }
                    let reasoning = row["reasoning"] as? [String: Any]
                    let efforts = (reasoning?["efforts"] as? [[String: Any]] ?? []).compactMap { effort -> MobileReasoningEffort? in
                        guard let effortID = effort["id"] as? String else { return nil }
                        return MobileReasoningEffort(id: effortID,
                            name: effort["name"] as? String ?? effortID,
                            description: effort["description"] as? String)
                    }
                    return MobileModelChoice(provider: provider, providerName: providerName, id: id,
                        name: row["name"] as? String ?? id,
                        description: row["description"] as? String, efforts: efforts,
                        defaultEffort: reasoning?["defaultEffort"] as? String)
                }
            }
        } catch {
            models = []
            currentModel = nil
        }
    }

    private func selectModel(sessionID: String, provider: String, model: String, effort: String?) async {
        modelSelectionBusy = true
        defer { modelSelectionBusy = false }
        do {
            var payload: [String: Any] = ["sessionId": sessionID, "provider": provider, "model": model]
            if let effort { payload["reasoningEffort"] = effort }
            let result = try await transport().call("session.selectModel", payload: payload)
            guard let selected = result["selected"] as? [String: Any],
                  let selectedProvider = selected["provider"] as? String,
                  let selectedModel = selected["model"] as? String else {
                throw TransportError.invalidResponse
            }
            currentModel = MobileModelSelection(provider: selectedProvider, model: selectedModel,
                reasoningEffort: selected["reasoningEffort"] as? String)
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        status = "连接失败"
        errorMessage = error.localizedDescription
    }

    private struct ToolRecord {
        var name: String
        var arguments: String
        var output: String?
        var isError = false
        var errorCode: String?
        var title: String?
        var summary: String?
        var rawInput: String?
        var settled = false
        var diffs: [MobileDiffHunk] = []
    }

    nonisolated private static func parseMessages(_ entries: [[String: Any]]) -> [MobileMessage] {
        struct PartialBlock {
            var firstSeq: Int
            var time: Date?
            var text: String
            var role: MobileMessageRole
        }
        var tools: [String: ToolRecord] = [:]
        var commands: [String: (name: String, args: String?, summary: String?, running: Bool, error: Bool)] = [:]
        var children: [String: [String]] = [:]
        var finalizedSteps = Set<String>()
        var endedTurns = Set<Int>()
        var lastAssistantSequenceByTurn: [Int: Int] = [:]
        var toolCallsByTurn: [Int: [String]] = [:]
        for wrapper in entries {
            let event = HarnessTranscriptParsing.event(from: wrapper)
            let data = HarnessTranscriptParsing.data(from: event)
            if event["type"] as? String == "assistant/message",
               let turn = (data["turn"] as? NSNumber)?.intValue,
               let step = (data["step"] as? NSNumber)?.intValue {
                finalizedSteps.insert("\(turn):\(step)")
                lastAssistantSequenceByTurn[turn] = (event["seq"] as? NSNumber)?.intValue ?? 0
            }
            switch event["type"] as? String {
            case "turn/end":
                if let turn = (data["turn"] as? NSNumber)?.intValue { endedTurns.insert(turn) }
            case "command/run":
                guard let id = data["commandId"] as? String else { break }
                commands[id] = (data["name"] as? String ?? "command", data["args"] as? String,
                                nil, true, false)
            case "command/done":
                guard let id = data["commandId"] as? String else { break }
                let old = commands[id] ?? ("command", nil, nil, true, false)
                commands[id] = (old.name, old.args, data["text"] as? String,
                                false, data["kind"] as? String == "error")
            case "tool/call":
                guard let id = data["callId"] as? String else { break }
                if let turn = (data["turn"] as? NSNumber)?.intValue,
                   !(toolCallsByTurn[turn] ?? []).contains(id) {
                    toolCallsByTurn[turn, default: []].append(id)
                }
                let view = (wrapper["view"] as? [String: Any])?["view"] as? [String: Any]
                var record = tools[id] ?? ToolRecord(name: "", arguments: "")
                record.name = data["name"] as? String ?? record.name
                record.arguments = data["arguments"] as? String ?? record.arguments
                record.title = view?["title"] as? String ?? record.title
                record.summary = view?["summary"] as? String ?? record.summary
                record.rawInput = Self.displayJSON(view?["rawInput"]) ?? record.rawInput
                record.diffs = Self.diffHunks(from: view)
                tools[id] = record
            case "tool/result":
                guard let result = HarnessTranscriptParsing.toolResult(from: data), !result.id.isEmpty else { break }
                var record = tools[result.id] ?? ToolRecord(name: "工具", arguments: "")
                record.output = result.output.isEmpty ? nil : result.output
                record.isError = result.isError
                record.errorCode = result.errorCode
                record.settled = true
                let view = (wrapper["view"] as? [String: Any])?["view"] as? [String: Any]
                record.title = view?["title"] as? String ?? record.title
                record.summary = view?["summary"] as? String ?? record.summary
                record.rawInput = Self.displayJSON(view?["rawInput"]) ?? record.rawInput
                // A settled result replaces the speculative call-time card,
                // matching the WebUI/macOS projection.
                record.diffs = Self.diffHunks(from: view)
                tools[result.id] = record
            case "tool/code-dispatch-start", "tool/code-dispatch":
                guard let parentID = data["parentCallId"] as? String,
                      let childID = data["subCallId"] as? String else { break }
                var record = tools[childID] ?? ToolRecord(name: "", arguments: "")
                record.name = data["name"] as? String ?? record.name
                record.arguments = Self.displayJSON(data["arguments"]) ?? record.arguments
                if event["type"] as? String == "tool/code-dispatch" {
                    let output = Self.nestedOutput(data["content"] as? [[String: Any]] ?? [])
                    record.output = output.isEmpty ? nil : output
                    record.isError = data["isError"] as? Bool ?? false
                    record.settled = true
                }
                tools[childID] = record
                if !(children[parentID] ?? []).contains(childID) {
                    children[parentID, default: []].append(childID)
                }
            default:
                break
            }
        }
        var result: [MobileMessage] = []
        var partials: [String: PartialBlock] = [:]
        for wrapper in entries {
            let event = HarnessTranscriptParsing.event(from: wrapper)
            guard let type = event["type"] as? String else { continue }
            let data = HarnessTranscriptParsing.data(from: event)
            let seq = (event["seq"] as? NSNumber)?.intValue ?? result.count
            let timeValue = (event["time"] as? NSNumber)?.doubleValue ?? 0
            let time = timeValue > 0 ? Date(timeIntervalSince1970: timeValue / 1000) : nil
            let message = HarnessTranscriptParsing.message(from: data)
            let content = HarnessTranscriptParsing.content(data: data, message: message)
            switch type {
            case "command/run":
                guard let id = data["commandId"] as? String, let command = commands[id] else { break }
                let suffix = command.args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = suffix.isEmpty ? "/\(command.name)" : "/\(command.name) \(suffix)"
                result.append(MobileMessage(id: "command-\(id)", role: .command, text: line, time: time,
                    detail: command.summary ?? (command.running ? "正在执行" : command.error ? "执行失败" : "已完成"),
                    isError: command.error, running: command.running))
            case "command/done":
                break
            case "user/message":
                guard HarnessTranscriptParsing.isVisibleUserMessage(data: data, message: message) else { continue }
                let text = HarnessTranscriptParsing.text(from: content)
                if !text.isEmpty { result.append(MobileMessage(id: "user-\(seq)", role: .user, text: text, time: time)) }
            case "assistant/message":
                let turn = (data["turn"] as? NSNumber)?.intValue ?? 0
                for (index, block) in content.enumerated() {
                    switch block["type"] as? String {
                    case "reasoning":
                        if let text = block["text"] as? String, !text.isEmpty {
                            result.append(MobileMessage(id: "reasoning-\(seq)-\(index)", role: .reasoning,
                                text: text, time: time))
                        }
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            result.append(MobileMessage(id: "assistant-\(seq)-\(index)", role: .assistant,
                                text: text, time: time))
                        }
                    case "tool-call":
                        let id = block["id"] as? String ?? "call-\(seq)-\(index)"
                        let record = tools[id]
                        let toolName = block["name"] as? String ?? record?.name ?? "tool"
                        let arguments = record?.arguments ?? block["arguments"] as? String ?? ""
                        result.append(Self.makeToolMessage(id: id, name: toolName, arguments: arguments,
                            time: time, tools: tools, children: children))
                    default: break
                    }
                }
                if endedTurns.contains(turn), lastAssistantSequenceByTurn[turn] == seq {
                    let diffs = (toolCallsByTurn[turn] ?? []).flatMap { id -> [MobileDiffHunk] in
                        guard let record = tools[id], record.settled, !record.isError else { return [] }
                        return record.diffs
                    }
                    if !diffs.isEmpty {
                        result.append(MobileMessage(id: "files-\(turn)-\(seq)", role: .files,
                            text: "", time: time, toolDiffs: diffs))
                    }
                }
            case "assistant/chunk":
                guard let turn = (data["turn"] as? NSNumber)?.intValue,
                      let step = (data["step"] as? NSNumber)?.intValue,
                      !finalizedSteps.contains("\(turn):\(step)"),
                      let chunk = data["chunk"] as? [String: Any],
                      let chunkType = chunk["type"] as? String else { break }
                let role: MobileMessageRole?
                switch chunkType {
                case "reasoning-delta": role = .reasoning
                case "text-delta": role = .assistant
                default: role = nil
                }
                guard let role, let delta = chunk["text"] as? String, !delta.isEmpty else { break }
                let index = (chunk["index"] as? NSNumber)?.intValue ?? 0
                let key = "\(turn):\(step):\(index):\(role == .reasoning ? "reasoning" : "text")"
                if partials[key] == nil {
                    partials[key] = PartialBlock(firstSeq: seq, time: time, text: "", role: role)
                }
                partials[key]?.text += delta
            case "turn/error":
                result.append(MobileMessage(id: "error-\(seq)", role: .notice, text: data["message"] as? String ?? "运行出错", time: time))
            default: break
            }
        }
        for (key, partial) in partials.sorted(by: { $0.value.firstSeq < $1.value.firstSeq }) {
            result.append(MobileMessage(id: "partial-\(key)", role: partial.role,
                text: partial.text, time: partial.time, running: true))
        }
        return result
    }

    private struct HistoryPollState: Sendable {
        var hasOpenTurn: Bool
        var promptCompleted: Bool
        static let empty = HistoryPollState(hasOpenTurn: false, promptCompleted: false)
    }

    nonisolated private static func historyState(_ entries: [[String: Any]], matchingPrompt: String?) -> HistoryPollState {
        var openTurns = Set<Int>()
        var matchingPromptSeq: Int?
        var lastTurnEndSeq: Int?
        for wrapper in entries {
            let event = HarnessTranscriptParsing.event(from: wrapper)
            let data = HarnessTranscriptParsing.data(from: event)
            let seq = (event["seq"] as? NSNumber)?.intValue ?? -1
            switch event["type"] as? String {
            case "turn/start":
                if let turn = (data["turn"] as? NSNumber)?.intValue { openTurns.insert(turn) }
            case "turn/end":
                if let turn = (data["turn"] as? NSNumber)?.intValue { openTurns.remove(turn) }
                lastTurnEndSeq = max(lastTurnEndSeq ?? seq, seq)
            case "user/message":
                guard let matchingPrompt else { break }
                let message = HarnessTranscriptParsing.message(from: data)
                let content = HarnessTranscriptParsing.content(data: data, message: message)
                if HarnessTranscriptParsing.isVisibleUserMessage(data: data, message: message),
                   HarnessTranscriptParsing.text(from: content)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == matchingPrompt {
                    matchingPromptSeq = seq
                }
            default: break
            }
        }
        return HistoryPollState(hasOpenTurn: !openTurns.isEmpty,
            promptCompleted: matchingPromptSeq.map { (lastTurnEndSeq ?? -1) > $0 } ?? false)
    }

    nonisolated private static func displayJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func nestedOutput(_ content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            if block["type"] as? String == "text" { return block["text"] as? String }
            guard JSONSerialization.isValidJSONObject(block),
                  let data = try? JSONSerialization.data(withJSONObject: block, options: [.prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }.joined(separator: "\n")
    }

    nonisolated private static func diffHunks(from view: [String: Any]?) -> [MobileDiffHunk] {
        guard view?["card"] as? String == "diff",
              let rows = view?["diffs"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let path = row["path"] as? String,
                  let newText = row["newText"] as? String else { return nil }
            let old = row["oldText"]
            guard old == nil || old is NSNull || old is String else { return nil }
            return MobileDiffHunk(path: path, oldText: old as? String, newText: newText)
        }
    }

    nonisolated private static func makeToolMessage(
        id: String,
        name: String,
        arguments: String,
        time: Date?,
        tools: [String: ToolRecord],
        children: [String: [String]],
        ancestors: Set<String> = []
    ) -> MobileMessage {
        let record = tools[id]
        let resolvedName = record?.name.isEmpty == false ? record!.name : name
        let resolvedArguments = record?.arguments.isEmpty == false ? record!.arguments : arguments
        let input = record?.rawInput ?? (resolvedArguments.isEmpty ? nil : resolvedArguments)
        let detail = [
            input.map { "输入\n\($0)" },
            record?.output.flatMap { $0.isEmpty ? nil : "输出\n\($0)" },
        ].compactMap { $0 }.joined(separator: "\n\n")
        let nested: [MobileMessage]
        if ancestors.count >= 256 {
            nested = []
        } else {
            nested = (children[id] ?? []).compactMap { childID in
                guard childID != id, !ancestors.contains(childID), let child = tools[childID] else { return nil }
                return makeToolMessage(id: childID, name: child.name, arguments: child.arguments,
                    time: time, tools: tools, children: children, ancestors: ancestors.union([id]))
            }
        }
        return MobileMessage(id: "tool-\(id)", role: .activity,
            text: toolTitle(resolvedName), time: time, detail: detail.isEmpty ? nil : detail,
            isError: record?.isError ?? false,
            toolName: resolvedName,
            running: !(record?.settled ?? false),
            toolSummary: record?.summary?.isEmpty == false
                ? record?.summary
                : toolSummary(name: resolvedName, arguments: resolvedArguments, fallback: id),
            toolInput: input,
            toolOutput: record?.output,
            toolErrorCode: record?.errorCode,
            toolChildren: nested,
            toolDiffs: record?.diffs ?? [])
    }

    nonisolated private static func toolTitle(_ name: String) -> String {
        switch name {
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "web_fetch": return "Fetch"
        case "pwsh": return "Pwsh"
        case "bash": return "Bash"
        case "read": return "Read"
        case "web_search": return "Search"
        case "write": return "Write"
        case "edit": return "Edit"
        case "run_code": return "Code"
        default: return "Tool call"
        }
    }

    nonisolated private static func toolSummary(name: String, arguments: String, fallback: String) -> String {
        let keys: [String]
        switch name {
        case "bash", "pwsh": keys = ["description", "command"]
        case "read", "web_fetch": keys = ["path", "file_path", "url"]
        case "web_search", "grep", "glob": keys = ["query", "pattern", "url"]
        case "write", "edit": keys = ["path", "file_path"]
        case "run_code": keys = ["description"]
        default: keys = []
        }
        let firstLine: (String) -> String = {
            $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? $0
        }
        var base = arguments.isEmpty ? fallback : firstLine(arguments)
        if let data = arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = keys.lazy.compactMap({ json[$0] as? String }).first(where: { !$0.isEmpty }) {
                base = firstLine(value)
            } else if let value = json.values.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                base = firstLine(value)
            }
        }
        if !["bash", "pwsh", "read", "web_fetch", "web_search", "grep", "glob", "write", "edit", "run_code"].contains(name),
           !name.isEmpty {
            return "\(name) · \(base)"
        }
        return base
    }
}
