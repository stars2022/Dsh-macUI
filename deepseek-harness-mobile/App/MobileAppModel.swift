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
    let profiles = ServerProfileStore()

    var selectedSession: MobileSession? { sessions.first { $0.id == selectedSessionID } }
    var currentWorkspace: MobileWorkspace? {
        guard let selectedSession else { return workspaces.first }
        if let owner = workspaces.first(where: { $0.sessionIDs.contains(selectedSession.id) }) { return owner }
        if selectedSession.blank, let cwd = selectedSession.cwd {
            return workspaces.first(where: { $0.path == cwd })
        }
        return nil
    }

    func start() async { await refresh() }

    func select(_ session: MobileSession) async {
        selectedSessionID = session.id
        await loadHistory(session.id)
        await loadModels(session.id)
    }

    func refresh() async {
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
            if selectedSessionID == nil, let first = sessions.first { await select(first) }
            else if let selectedSessionID {
                await loadHistory(selectedSessionID)
                await loadModels(selectedSessionID)
            }
        } catch { show(error) }
    }

    func createSession(workspaceID: String? = nil) async {
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
        guard !text.isEmpty, let sessionID = selectedSessionID else { return }
        draft = ""
        sending = true
        messages.append(MobileMessage(id: "local-\(UUID())", role: .user, text: text, time: Date()))
        defer { sending = false }
        do {
            let payload: [String: Any] = ["sessionId": sessionID, "mode": "queue",
                                          "content": [["type": "text", "text": text]],
                                          "clientTimeZone": TimeZone.current.identifier]
            _ = try await transport().call("session.prompt", payload: payload)
            var observedRunning = false
            for tick in 0..<1_200 {
                let history = await loadHistory(sessionID, reportErrors: false, matchingPrompt: text)
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
        selectedSessionID = nil
        messages = []
        models = []
        currentModel = nil
        status = "正在连接…"
        await refresh()
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
        var children: [String: [String]] = [:]
        var finalizedSteps = Set<String>()
        for wrapper in entries {
            let event = HarnessTranscriptParsing.event(from: wrapper)
            let data = HarnessTranscriptParsing.data(from: event)
            if event["type"] as? String == "assistant/message",
               let turn = (data["turn"] as? NSNumber)?.intValue,
               let step = (data["step"] as? NSNumber)?.intValue {
                finalizedSteps.insert("\(turn):\(step)")
            }
            switch event["type"] as? String {
            case "tool/call":
                guard let id = data["callId"] as? String else { break }
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
            case "user/message":
                guard HarnessTranscriptParsing.isVisibleUserMessage(data: data, message: message) else { continue }
                let text = HarnessTranscriptParsing.text(from: content)
                if !text.isEmpty { result.append(MobileMessage(id: "user-\(seq)", role: .user, text: text, time: time)) }
            case "assistant/message":
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
