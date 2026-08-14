import Foundation

final class HarnessAPI {
    static let shared = HarnessAPI()

    var baseURL: URL {
        get {
            if let stored = UserDefaults.standard.string(forKey: "serverURL"), let url = URL(string: stored) { return url }
            return URL(string: "http://localhost:3080")!
        }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "serverURL") }
    }

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    var onEvent: (() -> Void)?
    var onMuxFrame: (([String: Any]) -> Void)?
    var onConnectionState: ((Bool) -> Void)?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 35
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func connectEvents() {
        disconnectEvents()
        var components = URLComponents(url: baseURL.appendingPathComponent("api/events.mux"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return }
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        onConnectionState?(true)
        receiveNext(task)
    }

    func disconnectEvents() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, task === self.socket else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   var payload = envelope.dictionary("payload") {
                    if let rpcId = envelope["rpcId"] as? String { payload["_rpcId"] = rpcId }
                    DispatchQueue.main.async { self.onMuxFrame?(payload) }
                }
                DispatchQueue.main.async { self.onEvent?() }
                self.receiveNext(task)
            case .failure:
                DispatchQueue.main.async { self.onConnectionState?(false) }
                let work = DispatchWorkItem { [weak self] in self?.connectEvents() }
                self.reconnectWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            }
        }
    }

    func listSessions(completion: @escaping (Result<[SessionSummary], Error>) -> Void) {
        call("session.list", payload: [:]) { result in
            completion(result.flatMap { value in
                guard let rows = value["items"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
                return .success(rows.compactMap(SessionSummary.init))
            })
        }
    }

    func searchSessions(query: String, completion: @escaping (Result<(items: [SessionSearchHit], hasMore: Bool), Error>) -> Void) {
        call("session.search", payload: ["query": query]) { result in
            completion(result.map { value in
                let items: [SessionSearchHit] = (value["items"] as? [[String: Any]] ?? []).compactMap { row -> SessionSearchHit? in
                    guard let id = row["sessionId"] as? String else { return nil }
                    return SessionSearchHit(sessionId: id, snippet: row["snippet"] as? String ?? "")
                }
                return (items, value["hasMore"] as? Bool ?? false)
            })
        }
    }

    func feedbackList(sessionId: String, completion: @escaping (Result<[MessageFeedbackItem], Error>) -> Void) {
        call("messageFeedback/list", payload: ["args": ["request": ["sessionId": sessionId]]]) { result in
            completion(result.flatMap { value in
                guard value["ok"] as? Bool == true, let inner = value["value"] as? [String: Any] else {
                    if let error = value["error"] as? [String: Any] { return .failure(APIError.server(code: error["code"] as? String ?? "feedback-error", message: "无法读取消息反馈")) }
                    return .failure(APIError.invalidResponse)
                }
                return .success((inner["items"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let messageId = row["messageId"] as? String,
                          let rating = row["rating"] as? String,
                          let version = row["version"] as? String else { return nil }
                    return MessageFeedbackItem(messageId: messageId, rating: rating, note: row["note"] as? String, version: version)
                })
            })
        }
    }

    func feedbackPut(sessionId: String, messageId: String, rating: String, note: String? = nil, ifVersion: String?, completion: @escaping (Result<MessageFeedbackItem, Error>) -> Void) {
        var request: [String: Any] = ["sessionId": sessionId, "messageId": messageId, "rating": rating]
        if let note { request["note"] = note }
        request["ifVersion"] = ifVersion ?? NSNull()
        call("messageFeedback/put", payload: ["args": ["request": request]]) { result in
            completion(result.flatMap { value in
                guard value["ok"] as? Bool == true, let inner = value["value"] as? [String: Any],
                      let messageId = inner["messageId"] as? String, let rating = inner["rating"] as? String, let version = inner["version"] as? String else {
                    if let error = value["error"] as? [String: Any] { return .failure(APIError.server(code: error["code"] as? String ?? "feedback-error", message: "无法保存消息反馈")) }
                    return .failure(APIError.invalidResponse)
                }
                return .success(MessageFeedbackItem(messageId: messageId, rating: rating, note: inner["note"] as? String, version: version))
            })
        }
    }

    func feedbackDelete(sessionId: String, messageId: String, version: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let request: [String: Any] = ["sessionId": sessionId, "messageId": messageId, "ifVersion": version]
        call("messageFeedback/delete", payload: ["args": ["request": request]]) { result in
            completion(result.flatMap { value in value["ok"] as? Bool == true ? .success(()) : .failure(APIError.invalidResponse) })
        }
    }

    func pluginInventory(completion: @escaping (Result<[PluginInventoryEntry], Error>) -> Void) {
        // pluginInventory is a Typert Remote, so it uses the slash carrier
        // rather than the dot-named api-proxy domains.
        call("pluginInventory/list", payload: ["args": [:]]) { result in
            completion(result.flatMap(Self.parsePluginInventorySnapshot))
        }
    }

    static func parsePluginInventorySnapshot(_ value: [String: Any]) -> Result<[PluginInventoryEntry], Error> {
        // The HTTP carrier already unwraps RpcResponse.result.value. Older
        // native builds expected a second Typert {ok,value} envelope and
        // rejected the valid {entries:[...]} snapshot. Keep the nested arm for
        // compatibility with fixtures/proxies that still expose that wrapper.
        let snapshot = value["value"] as? [String: Any] ?? value
        guard let rows = snapshot["entries"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
        return .success(rows.compactMap { row in
            guard let id = row["entryId"] as? String, let module = row["moduleName"] as? String else { return nil }
            return PluginInventoryEntry(entryId: id, moduleName: module,
                                        enabled: row["enabled"] as? Bool ?? false,
                                        fiberPhase: row["fiberPhase"] as? String)
        })
    }

    func cordisInventory(completion: @escaping (Result<[CordisInventoryRow], Error>) -> Void) {
        call("dynamicCordisRunner/inventory", payload: ["args": [:]]) { result in
            completion(result.flatMap { value in
                // This Remote returns the inventory array directly. `call`
                // preserves top-level arrays under `_array` because its shared
                // result carrier is dictionary-shaped.
                guard let rows = value["_array"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
                return .success(rows.compactMap(Self.cordisInventoryRow))
            })
        }
    }

    func cordisStop(agentId: String, pluginId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        cordisAction("stopFromPanel", agentId: agentId, pluginId: pluginId) { result in
            completion(result.flatMap { value in
                if value["ok"] as? Bool == true || value["reason"] as? String == "not-running" { return .success(()) }
                return .failure(APIError.server(code: value["reason"] as? String ?? "cordis-stop-failed",
                                                message: value["message"] as? String ?? "无法停止 Cordis 插件"))
            })
        }
    }

    func cordisRemove(agentId: String, pluginId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        cordisAction("undefineFromPanel", agentId: agentId, pluginId: pluginId) { result in
            completion(result.flatMap { value in
                if value["ok"] as? Bool == true { return .success(()) }
                return .failure(APIError.server(code: value["reason"] as? String ?? "cordis-remove-failed",
                                                message: value["message"] as? String ?? "无法移除 Cordis 插件"))
            })
        }
    }

    private func cordisAction(_ method: String, agentId: String, pluginId: String,
                              completion: @escaping (Result<[String: Any], Error>) -> Void) {
        call("dynamicCordisRunner/\(method)", payload: ["args": ["agentId": agentId, "pluginId": pluginId]], completion: completion)
    }

    func modelProviderSettings(completion: @escaping (Result<(rows: [ModelProviderSettings], writable: Bool), Error>) -> Void) {
        let group = DispatchGroup()
        var providersResult: Result<[[String: Any]], Error>?
        var settingsResult: Result<[String: Any], Error>?
        group.enter(); call("llm.providers", payload: [:]) { result in
            providersResult = result.flatMap { value in
                guard let rows = value["providers"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
                return .success(rows)
            }; group.leave()
        }
        group.enter(); call("settings.describe", payload: [:]) { result in settingsResult = result; group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self, let providersResult, let settingsResult else { completion(.failure(APIError.invalidResponse)); return }
            switch (providersResult, settingsResult) {
            case let (.failure(error), _), let (_, .failure(error)): completion(.failure(error))
            case let (.success(providerRows), .success(settings)):
                let namespaces = settings["namespaces"] as? [[String: Any]] ?? []
                let byNamespace = Dictionary(uniqueKeysWithValues: namespaces.compactMap { row -> (String, [String: Any])? in
                    guard let ns = row["ns"] as? String else { return nil }; return (ns, row)
                })
                let preliminary: [(row: [String: Any], namespace: [String: Any]?, profile: [String: Any]?, userProfile: Any?)] = providerRows.map { provider in
                    let ns = (provider["settingsNs"] as? String).flatMap { byNamespace[$0] }
                    let path = provider["settingsPath"] as? [String] ?? []
                    return (provider, ns, Self.dictionaryAtPath(ns?["value"], path: path), Self.valueAtPath(ns?["user"], path: path))
                }
                let refs = Array(Set(preliminary.compactMap { $0.profile?["apiKeyEnv"] as? String }))
                let finish: ([String: CredentialStatus]) -> Void = { credentials in
                    let rows = preliminary.compactMap { item -> ModelProviderSettings? in
                        guard let id = item.row["provider"] as? String,
                              let nsName = item.row["settingsNs"] as? String else { return nil }
                        let path = item.row["settingsPath"] as? [String] ?? []
                        let ref = item.profile?["apiKeyEnv"] as? String
                        let namespaceUser = item.namespace?["user"]
                        let removable = !path.isEmpty && Self.valueAtPath(namespaceUser, path: path) != nil
                            && Self.valueAtPath(item.namespace?["base"], path: path) == nil
                        return ModelProviderSettings(id: id, displayName: item.row["displayName"] as? String ?? id,
                            settingsNamespace: nsName, settingsPath: path,
                            active: item.row["active"] as? Bool ?? false, declared: item.row["declared"] as? Bool,
                            configured: item.profile != nil, removable: removable,
                            apiKeyRef: ref, credential: ref.flatMap { credentials[$0] }, profile: item.profile ?? [:],
                            revision: item.namespace?["revision"] as? Int ?? 0, applies: item.namespace?["applies"] as? String ?? "live")
                    }
                    completion(.success((rows, settings["writable"] as? Bool ?? false)))
                }
                guard !refs.isEmpty else { finish([:]); return }
                self.call("credentials.describe", payload: ["refs": refs]) { result in
                    let map: [String: CredentialStatus]
                    if case let .success(value) = result, let raw = value["credentials"] as? [String: [String: Any]] {
                        map = raw.mapValues { CredentialStatus(configured: $0["configured"] as? Bool ?? false,
                                                               source: $0["source"] as? String,
                                                               writable: $0["writable"] as? Bool ?? false) }
                    } else { map = [:] }
                    finish(map)
                }
            }
        }
    }

    func setCredential(ref: String, value: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("credentials.set", payload: ["ref": ref, "value": value]) { completion($0.map { _ in () }) }
    }

    func unsetCredential(ref: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("credentials.unset", payload: ["ref": ref]) { completion($0.map { _ in () }) }
    }

    func mutateSettings(ns: String, ops: [[String: Any]], expectedRevision: Int? = nil,
                        completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var payload: [String: Any] = ["ns": ns, "ops": ops]
        if let expectedRevision { payload["expectedRevision"] = expectedRevision }
        call("settings.mutate", payload: payload, completion: completion)
    }

    func settings(completion: @escaping (Result<HostSettingsSnapshot, Error>) -> Void) {
        call("settings.describe", payload: [:]) { result in
            completion(result.map { settings in
                HostSettingsSnapshot(
                    namespaces: Self.settingsNamespaces(settings["namespaces"] as? [[String: Any]] ?? []),
                    writable: settings["writable"] as? Bool ?? false,
                    hasDocument: settings["hasDocument"] as? Bool ?? false
                )
            })
        }
    }

    func openSettingsDocument(completion: @escaping (Result<Void, Error>) -> Void) {
        call("settings.openDocument", payload: [:]) { result in
            completion(result.flatMap { value in
                value["opened"] as? Bool == true ? .success(()) : .failure(APIError.invalidResponse)
            })
        }
    }

    func pluginSettings(completion: @escaping (Result<PluginSettingsSnapshot, Error>) -> Void) {
        call("settings.describe", payload: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(settings):
                let wanted = Set(["shell", "agent-loop", "web-search-deepseek"])
                let namespaces = Self.settingsNamespaces(settings["namespaces"] as? [[String: Any]] ?? [])
                    .filter { wanted.contains($0.ns) }
                let search = namespaces.first { $0.ns == "web-search-deepseek" }
                let ref = search?.value["apiKeyEnv"] as? String ?? "DEEPSEEK_API_KEY"
                let finish: (CredentialStatus?) -> Void = { credential in
                    completion(.success(PluginSettingsSnapshot(
                        namespaces: namespaces,
                        writable: settings["writable"] as? Bool ?? false,
                        webSearchCredential: credential
                    )))
                }
                self.call("credentials.describe", payload: ["refs": [ref]]) { credentialResult in
                    guard case let .success(value) = credentialResult,
                          let raw = (value["credentials"] as? [String: [String: Any]])?[ref] else {
                        finish(nil); return
                    }
                    finish(CredentialStatus(configured: raw["configured"] as? Bool ?? false,
                                            source: raw["source"] as? String,
                                            writable: raw["writable"] as? Bool ?? true))
                }
            }
        }
    }

    func openPath(_ path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("host.openPath", payload: ["path": path]) { completion($0.map { _ in () }) }
    }

    private static func valueAtPath(_ root: Any?, path: [String]) -> Any? {
        guard !path.isEmpty else { return root is NSNull ? nil : root }
        var value = root
        for component in path {
            guard let dictionary = value as? [String: Any] else { return nil }
            value = dictionary[component]
        }
        return value is NSNull ? nil : value
    }

    private static func settingsNamespaces(_ rows: [[String: Any]]) -> [SettingsNamespaceSnapshot] {
        rows.compactMap { row in
            guard let ns = row["ns"] as? String else { return nil }
            return SettingsNamespaceSnapshot(
                ns: ns,
                value: row["value"] as? [String: Any] ?? [:],
                base: row["base"] as? [String: Any] ?? [:],
                user: row["user"] as? [String: Any] ?? [:],
                revision: row["revision"] as? Int ?? 0,
                applies: row["applies"] as? String ?? "live"
            )
        }
    }

    private static func dictionaryAtPath(_ root: Any?, path: [String]) -> [String: Any]? {
        valueAtPath(root, path: path) as? [String: Any]
    }

    func listWorkspaces(completion: @escaping (Result<(items: [WorkspaceSummary], archivedSessionIds: [String]), Error>) -> Void) {
        call("workspace.list", payload: [:]) { result in
            completion(result.flatMap { value in
                let rows = value["items"] as? [[String: Any]] ?? value["workspaces"] as? [[String: Any]] ?? []
                return .success((rows.compactMap(WorkspaceSummary.init), value["archivedSessionIds"] as? [String] ?? []))
            })
        }
    }

    func createWorkspace(path: String, completion: @escaping (Result<WorkspaceSummary, Error>) -> Void) {
        call("workspace.create", payload: ["path": path]) { result in
            completion(result.flatMap { value in
                guard let row = value["workspace"] as? [String: Any], let workspace = WorkspaceSummary(json: row) else { return .failure(APIError.invalidResponse) }
                return .success(workspace)
            })
        }
    }

    func renameWorkspace(id: String, title: String, completion: @escaping (Result<WorkspaceSummary, Error>) -> Void) {
        call("workspace.rename", payload: ["workspaceId": id, "title": title]) { result in
            completion(result.flatMap { value in
                guard let row = value["workspace"] as? [String: Any], let workspace = WorkspaceSummary(json: row) else { return .failure(APIError.invalidResponse) }
                return .success(workspace)
            })
        }
    }

    func deleteWorkspace(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("workspace.delete", payload: ["workspaceId": id]) { result in completion(result.map { _ in () }) }
    }

    func insertWorkspaceBefore(id: String, beforeId: String?, completion: @escaping (Result<[String], Error>) -> Void) {
        var payload: [String: Any] = ["workspaceId": id]
        if let beforeId { payload["beforeWorkspaceId"] = beforeId }
        call("workspace.insertBefore", payload: payload) { result in
            completion(result.flatMap { value in
                guard let ids = value["workspaceIds"] as? [String] else { return .failure(APIError.invalidResponse) }
                return .success(ids)
            })
        }
    }

    func archiveSession(_ id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("workspace.archiveSession", payload: ["sessionId": id]) { result in completion(result.map { _ in () }) }
    }

    func insertSession(workspaceId: String, sessionId: String, beforeSessionId: String?, completion: @escaping (Result<WorkspaceSummary, Error>) -> Void) {
        var payload: [String: Any] = ["workspaceId": workspaceId, "sessionId": sessionId]
        if let beforeSessionId { payload["beforeSessionId"] = beforeSessionId }
        call("workspace.insertSessionBefore", payload: payload) { result in
            completion(result.flatMap { value in
                guard let row = value["workspace"] as? [String: Any], let workspace = WorkspaceSummary(json: row) else { return .failure(APIError.invalidResponse) }
                return .success(workspace)
            })
        }
    }

    func createSession(cwd: String?, workspaceId: String? = nil, agentPreset: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        var payload: [String: Any] = [:]
        if let workspaceId { payload["workspaceId"] = workspaceId }
        else if let cwd { payload["cwd"] = cwd }
        if let agentPreset { payload["agentPreset"] = agentPreset }
        call("session.create", payload: payload) { result in
            completion(result.flatMap { value in
                guard let id = value["sessionId"] as? String else { return .failure(APIError.invalidResponse) }
                return .success(id)
            })
        }
    }

    func listAgentPresets(completion: @escaping (Result<(presets: [AgentPresetEntry], authorable: Bool, hasDocument: Bool), Error>) -> Void) {
        call("agentPreset.list", payload: [:]) { result in
            completion(result.map { value in
                let presets: [AgentPresetEntry] = (value["presets"] as? [[String: Any]] ?? []).compactMap { row -> AgentPresetEntry? in
                    guard let id = row["id"] as? String else { return nil }
                    return AgentPresetEntry(id: id, trust: row["trust"] as? String ?? "system", isDefault: row["isDefault"] as? Bool ?? false,
                        name: row["name"] as? String, description: row["description"] as? String, broken: row["broken"] as? String)
                }
                return (presets, value["authorable"] as? Bool ?? false, value["hasDocument"] as? Bool ?? false)
            })
        }
    }

    func readAgentPreset(_ id: String, completion: @escaping (Result<(content: String, trust: String, description: String?), Error>) -> Void) {
        call("agentPreset.read", payload: ["agentPreset": id]) { result in
            completion(result.flatMap { value in
                guard let content = value["content"] as? String else { return .failure(APIError.invalidResponse) }
                return .success((content, value["trust"] as? String ?? "system", value["description"] as? String))
            })
        }
    }

    func copyAgentPreset(from: String, to: String, name: String?, completion: @escaping (Result<String, Error>) -> Void) {
        var payload: [String: Any] = ["from": from, "agentPreset": to]
        if let name, !name.isEmpty { payload["name"] = name }
        call("agentPreset.copy", payload: payload) { result in completion(result.flatMap { value in
            guard let id = value["agentPreset"] as? String else { return .failure(APIError.invalidResponse) }; return .success(id)
        }) }
    }

    func openAgentPreset(_ id: String, completion: @escaping (Result<(opened: Bool, path: String?), Error>) -> Void) {
        call("agentPreset.openDocument", payload: ["agentPreset": id]) { result in
            completion(result.map { value in (value["opened"] as? Bool ?? false, value["path"] as? String) })
        }
    }

    func removeAgentPreset(_ id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("agentPreset.remove", payload: ["agentPreset": id]) { result in completion(result.map { _ in () }) }
    }

    func selectAgentPreset(sessionId: String, preset: String, completion: @escaping (Result<String, Error>) -> Void) {
        call("agentPreset.select", payload: ["sessionId": sessionId, "agentPreset": preset]) { result in
            completion(result.flatMap { value in
                guard let selected = value["agentPreset"] as? String else { return .failure(APIError.invalidResponse) }
                return .success(selected)
            })
        }
    }

    func listSubagents(parentSessionId: String, completion: @escaping (Result<(entries: [SubagentEntry], parentAvailable: Bool), Error>) -> Void) {
        call("subagent.list", payload: ["parentSessionId": parentSessionId]) { result in
            completion(result.map { value in
                let entries = (value["entries"] as? [[String: Any]] ?? []).compactMap { row -> SubagentEntry? in
                    guard let id = row["id"] as? String, let kind = row["kind"] as? String else { return nil }
                    if kind == "diagnostic" { return SubagentEntry(id: id, mode: "", activity: "", hasChildren: false, label: nil, diagnostic: row["reason"] as? String ?? "unavailable", tokenUsage: nil, durationMs: nil) }
                    return SubagentEntry(id: id, mode: row["mode"] as? String ?? "one-shot", activity: row["activity"] as? String ?? "inactive",
                        hasChildren: row["hasChildren"] as? Bool ?? false, label: row["label"] as? String, diagnostic: nil,
                        tokenUsage: row.dictionary("tokenUsage").map(TokenUsage.init),
                        durationMs: row["durationMs"] as? Int ?? (row["durationMs"] as? Double).map(Int.init))
                }
                return (entries, value["parentAvailable"] as? Bool ?? false)
            })
        }
    }

    func interruptSubagent(parentSessionId: String, childSessionId: String, mode: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("subagent.interrupt", payload: ["parentSessionId": parentSessionId, "childSessionId": childSessionId, "mode": mode]) { result in completion(result.map { _ in () }) }
    }

    func history(sessionId: String, completion: @escaping (Result<HistorySnapshot, Error>) -> Void) {
        call("session.history", payload: ["sessionId": sessionId, "maxMessages": 120]) { result in
            completion(result.flatMap { value in
                guard let entries = value["events"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
                return .success(HistorySnapshot(items: Self.parseHistory(entries),
                    hasMore: value["hasMore"] as? Bool ?? false,
                    projections: Self.parseProjections(value.dictionary("projections")),
                    trajectory: Self.parseTrajectory(entries)))
            })
        }
    }

    func subagentHistory(parentSessionId: String, childSessionId: String, mode: String, completion: @escaping (Result<HistorySnapshot, Error>) -> Void) {
        call("subagent.history", payload: ["parentSessionId": parentSessionId, "childSessionId": childSessionId, "mode": mode, "maxMessages": 120]) { result in
            completion(result.flatMap { value in
                guard let entries = value["events"] as? [[String: Any]] else { return .failure(APIError.invalidResponse) }
                return .success(HistorySnapshot(items: Self.parseHistory(entries), hasMore: value["hasMore"] as? Bool ?? false,
                    projections: Self.parseProjections(value.dictionary("projections")), trajectory: Self.parseTrajectory(entries)))
            })
        }
    }

    func models(sessionId: String, completion: @escaping (Result<ModelCatalogSnapshot, Error>) -> Void) {
        call("session.models", payload: ["sessionId": sessionId]) { result in
            completion(result.flatMap { value in
                guard let current = value["current"] as? [String: Any], let provider = current["provider"] as? String, let model = current["model"] as? String else {
                    return .failure(APIError.invalidResponse)
                }
                var choices: [ModelChoice] = []
                for group in value["groups"] as? [[String: Any]] ?? [] {
                    guard let providerId = group["id"] as? String else { continue }
                    let providerName = group["name"] as? String ?? providerId
                    for row in group["models"] as? [[String: Any]] ?? [] {
                        guard let id = row["id"] as? String else { continue }
                        let reasoning = row["reasoning"] as? [String: Any]
                        let efforts = (reasoning?["efforts"] as? [[String: Any]] ?? []).compactMap { effort -> ReasoningEffort? in
                            guard let effortId = effort["id"] as? String else { return nil }
                            return ReasoningEffort(id: effortId, name: effort["name"] as? String ?? effortId,
                                                   description: effort["description"] as? String)
                        }
                        choices.append(ModelChoice(provider: providerId, providerName: providerName, id: id,
                                                   name: row["name"] as? String ?? id,
                                                   description: row["description"] as? String, efforts: efforts,
                                                   defaultEffort: reasoning?["defaultEffort"] as? String))
                    }
                }
                let failures = (value["failures"] as? [[String: Any]] ?? []).compactMap { row -> ModelCatalogFailure? in
                    guard let id = row["id"] as? String, let message = row["message"] as? String else { return nil }
                    return ModelCatalogFailure(id: id, name: row["name"] as? String ?? id, message: message)
                }
                return .success(ModelCatalogSnapshot(
                    current: ModelSelection(provider: provider, model: model,
                        reasoningEffort: current["reasoningEffort"] as? String),
                    choices: choices, failures: failures, routable: value["routable"] as? Bool ?? false))
            })
        }
    }

    func commands(sessionId: String, completion: @escaping (Result<[CommandDescriptor], Error>) -> Void) {
        call("commands/list", payload: ["args": ["agentId": sessionId]]) { result in
            completion(result.flatMap { value in
                // Typert Remotes return an array directly, while the core
                // RPC helper is dictionary-shaped. The transport wraps array
                // values under the internal sentinel before this point.
                let rows = value["_array"] as? [[String: Any]] ?? value["commands"] as? [[String: Any]] ?? []
                return .success(rows.compactMap { row in
                    guard let name = row["name"] as? String, let description = row["description"] as? String else { return nil }
                    return CommandDescriptor(name: name, description: description,
                        inputHint: row.dictionary("input")?["hint"] as? String)
                })
            })
        }
    }

    /// Execute a Host slash command without routing its text through the LLM.
    /// The Host durably emits command/run + command/done, which the transcript
    /// renders as `name · settlement` (for example permission · preset ...).
    func executeCommand(sessionId: String, line: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        call("commands/execute", payload: ["args": ["agentId": sessionId, "line": line]]) { result in
            completion(result.flatMap { value in
                guard value["commandId"] as? String != nil else {
                    return .failure(APIError.server(code: "command-unmatched",
                                                    message: "当前 Host 未提供命令：\(line)"))
                }
                return .success(())
            })
        }
    }

    func selectModel(sessionId: String, selection: ModelSelection, completion: @escaping (Result<ModelSelection, Error>) -> Void) {
        var payload: [String: Any] = ["sessionId": sessionId, "provider": selection.provider, "model": selection.model]
        if let effort = selection.reasoningEffort { payload["reasoningEffort"] = effort }
        call("session.selectModel", payload: payload) { result in
            completion(result.flatMap { value in
                guard let selected = value.dictionary("selected"),
                      let provider = selected["provider"] as? String,
                      let model = selected["model"] as? String else { return .failure(APIError.invalidResponse) }
                return .success(ModelSelection(provider: provider, model: model,
                    reasoningEffort: selected["reasoningEffort"] as? String))
            })
        }
    }

    static func forkPayload(sessionId: String, atSeq: Int?) -> [String: Any] {
        var payload: [String: Any] = ["sessionId": sessionId]
        if let atSeq { payload["atSeq"] = atSeq }
        return payload
    }

    func fork(sessionId: String, atSeq: Int?, completion: @escaping (Result<String, Error>) -> Void) {
        call("session.fork", payload: Self.forkPayload(sessionId: sessionId, atSeq: atSeq)) { result in
            completion(result.flatMap { value in
                guard let id = value["sessionId"] as? String else { return .failure(APIError.invalidResponse) }
                return .success(id)
            })
        }
    }

    func prompt(sessionId: String, text: String, images: [DraftImage] = [], files: [DraftTextFile] = [], mode: String = "queue", completion: @escaping (Result<Void, Error>) -> Void) {
        var content: [[String: Any]] = images.map { image in
            ["type": "image", "mediaType": image.mediaType, "data": image.data.base64EncodedString(), "name": image.name]
        }
        content.append(contentsOf: files.compactMap { file in
            file.promptText.map { ["type": "text", "text": $0] }
        })
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "mode": mode,
            "content": content,
            "clientTimeZone": TimeZone.current.identifier,
        ]
        call("session.prompt", payload: payload) { result in completion(result.map { _ in () }) }
    }

    func subagentPrompt(parentSessionId: String, childSessionId: String, mode: String, text: String, images: [DraftImage] = [], files: [DraftTextFile] = [], completion: @escaping (Result<String, Error>) -> Void) {
        var content: [[String: Any]] = images.map { image in ["type": "image", "mediaType": image.mediaType, "data": image.data.base64EncodedString(), "name": image.name] }
        content.append(contentsOf: files.compactMap { file in file.promptText.map { ["type": "text", "text": $0] } })
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        let payload: [String: Any] = ["parentSessionId": parentSessionId, "childSessionId": childSessionId, "mode": mode, "content": content, "clientTimeZone": TimeZone.current.identifier]
        call("subagent.prompt", payload: payload) { result in completion(result.flatMap { value in
            guard let id = value["messageId"] as? String else { return .failure(APIError.invalidResponse) }; return .success(id)
        }) }
    }

    func cancel(sessionId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("session.cancel", payload: ["sessionId": sessionId]) { result in completion(result.map { _ in () }) }
    }

    func setPermission(sessionId: String, permission: String, completion: @escaping (Result<Void, Error>) -> Void) {
        executeCommand(sessionId: sessionId, line: "/permission \(permission)", completion: completion)
    }

    func rename(sessionId: String, title: String, completion: @escaping (Result<Void, Error>) -> Void) {
        call("session.rename", payload: ["sessionId": sessionId, "title": title]) { result in completion(result.map { _ in () }) }
    }

    func updateQueue(sessionId: String, itemId: String, action: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        call("session.updateQueue", payload: ["sessionId": sessionId, "itemId": itemId, "action": action]) {
            completion($0.map { _ in () })
        }
    }

    func mutateGoal(method: String, sessionId: String, goal: GoalSnapshot, objective: String? = nil,
                    completion: @escaping (Result<Void, Error>) -> Void) {
        var payload: [String: Any] = ["sessionId": sessionId,
            "ref": ["id": goal.id, "revision": goal.revision]]
        if let objective { payload["objective"] = objective }
        call(method, payload: payload) { completion($0.map { _ in () }) }
    }

    /// GET download surface used by the WebUI Session-log header action.
    /// This is intentionally not sent through the JSON RPC carrier: the Host
    /// responds with the ZIP bytes directly.
    func downloadSessionLog(sessionId: String, includeDescendants: Bool = true,
                            completion: @escaping (Result<Data, Error>) -> Void) {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/session.export"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "includeDescendants", value: includeDescendants ? "true" : "false"),
        ]
        guard let url = components.url else { completion(.failure(APIError.invalidResponse)); return }
        session.dataTask(with: url) { data, response, error in
            let result: Result<Data, Error>
            if let error {
                result = .failure(APIError.transport(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(APIError.transport("HTTP \(http.statusCode)"))
            } else if let data, !data.isEmpty {
                result = .success(data)
            } else {
                result = .failure(APIError.invalidResponse)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func respond(rpcId: String, result: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = ["type": "client-response", "rpcId": rpcId, "result": result]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/respond"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { completion(.failure(error)); return }
        session.dataTask(with: request) { data, response, error in
            let resolved: Result<Void, Error>
            if let error { resolved = .failure(APIError.transport(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                resolved = .failure(APIError.transport("HTTP \(http.statusCode)"))
            } else if let data,
                      let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      receipt["accepted"] as? Bool == true {
                resolved = .success(())
            } else if let data,
                      let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reason = receipt["reason"] as? String {
                resolved = .failure(APIError.server(code: "response-rejected", message: reason))
            } else { resolved = .failure(APIError.invalidResponse) }
            DispatchQueue.main.async { completion(resolved) }
        }.resume()
    }

    private func call(_ method: String, payload: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let rpcId = UUID().uuidString.lowercased()
        let body: [String: Any] = ["type": "client-request", "rpcId": rpcId, "method": method, "payload": payload]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        catch { completion(.failure(error)); return }

        session.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Error>
            if let error { result = .failure(APIError.transport(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                result = .failure(APIError.transport("HTTP \(http.statusCode)"))
            } else if let data,
                      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let serverResult = envelope["result"] as? [String: Any] {
                if serverResult["ok"] as? Bool == true, let value = serverResult["value"] as? [String: Any] {
                    result = .success(value)
                } else if serverResult["ok"] as? Bool == true, let value = serverResult["value"] as? [[String: Any]] {
                    result = .success(["_array": value])
                } else if let detail = serverResult["error"] as? [String: Any] {
                    result = .failure(APIError.rpcServer(json: detail))
                } else { result = .failure(APIError.invalidResponse) }
            } else { result = .failure(APIError.invalidResponse) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private struct ToolRecord {
        var name: String
        var arguments: String
        var callTitle: String?
        var resultTitle: String?
        var rawInput: String?
        var callView: [String: Any]?
        var resultView: [String: Any]?
        var output: String?
        var resultMeta: [String: Any]?
        var resultSeq: Int?
        var settled = false
        var isError = false
        var stopped = false
        var errorCode: String?
    }

    private struct CommandRecord {
        var name: String?
        var args: String?
        var seq: Int
        var time: Double
        var outcomeKind: String?
        var outcomeText: String?
    }

    static func parseHistory(_ entries: [[String: Any]]) -> [ConversationItem] {
        // History includes streaming chunks and bookkeeping events. They are
        // not presentation nodes and can be skipped before both passes.
        let presentationEntries = entries.filter { entry in
            let event = entry["event"] as? [String: Any] ?? entry
            switch event["type"] as? String {
            case "user/message", "assistant/message", "tool/call", "tool/result", "tool/code-dispatch-start", "tool/code-dispatch", "command/run", "command/done", "turn/error", "turn/max-tokens": return true
            default: return false
            }
        }
        var tools: [String: ToolRecord] = [:]
        var children: [String: [String]] = [:]
        var producedByTurn: [Int: [(seq: Int, callId: String, path: String)]] = [:]
        var lastAssistantByTurn: [Int: Int] = [:]
        var endedTurns = Set<Int>()
        var turnStarts: [Int: Double] = [:]
        var turnEnds: [Int: Double] = [:]
        var stepStarts: [String: Double] = [:]
        var firstTokens: [String: Double] = [:]
        var assistantReadings: [Int: [(step: Int, ttft: Double?, decode: Double?, output: Int?)]] = [:]
        var commands: [String: CommandRecord] = [:]

        for entry in entries {
            let event = entry["event"] as? [String: Any] ?? entry
            let data = event.dictionary("data") ?? [:]
            let turn = data.int("turn")
            let step = data.int("step")
            let stepKey = "\(turn):\(step)"
            let time = event.double("time")
            switch event["type"] as? String {
            case "turn/start": turnStarts[turn] = time
            case "turn/end": endedTurns.insert(turn); turnEnds[turn] = time
            case "step/start": stepStarts[stepKey] = time
            case "assistant/chunk":
                guard firstTokens[stepKey] == nil, let chunk = data.dictionary("chunk"), Self.chunkCarriesToken(chunk) else { break }
                firstTokens[stepKey] = time
            case "assistant/message":
                lastAssistantByTurn[turn] = event.int("seq")
                let first = firstTokens[stepKey]
                let start = stepStarts[stepKey]
                let usage = data.dictionary("usage")
                assistantReadings[turn, default: []].append((
                    step,
                    start.flatMap { start in first.map { max(0, $0 - start) } },
                    first.map { max(0, time - $0) },
                    usage.map { $0.int("outputTokens") }
                ))
            case "command/run":
                guard let id = data["commandId"] as? String else { break }
                commands[id] = CommandRecord(name: data["name"] as? String, args: data["args"] as? String,
                                             seq: event.int("seq"), time: time, outcomeKind: nil, outcomeText: nil)
            case "command/done":
                guard let id = data["commandId"] as? String else { break }
                var record = commands[id] ?? CommandRecord(name: nil, args: nil, seq: event.int("seq"), time: time,
                                                           outcomeKind: nil, outcomeText: nil)
                record.outcomeKind = data["kind"] as? String
                record.outcomeText = data["text"] as? String
                commands[id] = record
            default: break
            }
        }

        var turnMetrics: [Int: MessageMetrics] = [:]
        for turn in endedTurns {
            let readings = (assistantReadings[turn] ?? []).sorted { $0.step < $1.step }
            let firstStepTTFT = readings.first?.ttft
            let sampled = readings.compactMap { reading -> (Double, Int)? in
                guard let decode = reading.decode, decode > 0, let output = reading.output else { return nil }
                return (decode, output)
            }
            let decodeMs = sampled.reduce(0) { $0 + $1.0 }
            let outputTokens = sampled.reduce(0) { $0 + $1.1 }
            let throughput = decodeMs > 0 ? Double(outputTokens) / (decodeMs / 1_000) : nil
            let runMs = turnStarts[turn].flatMap { start in turnEnds[turn].map { max(0, $0 - start) } }
            turnMetrics[turn] = MessageMetrics(runMs: runMs, ttftMs: firstStepTTFT, tokensPerSecond: throughput)
        }

        // The Host owns presentation intent. Capture call views and settled
        // results first, then render the ordered blocks inside assistant messages.
        for entry in presentationEntries {
            let event = entry["event"] as? [String: Any] ?? entry
            guard let type = event["type"] as? String else { continue }
            let data = event["data"] as? [String: Any] ?? [:]
            switch type {
            case "tool/call":
                guard let id = data["callId"] as? String else { continue }
                let intent = entry.dictionary("view")?.dictionary("view")
                var record = tools[id] ?? ToolRecord(name: "", arguments: "")
                record.name = data["name"] as? String ?? record.name
                record.arguments = data["arguments"] as? String ?? record.arguments
                record.callView = intent
                record.callTitle = intent?["title"] as? String
                record.rawInput = displayJSON(intent?["rawInput"])
                tools[id] = record
                let turn = data.int("turn")
                let card = intent?["card"] as? String
                let kind = intent?["kind"] as? String
                if card == "diff" || (card == "generic" && kind == "edit") {
                    for location in intent?.array("locations") ?? [] {
                        if let path = location["path"] as? String {
                            producedByTurn[turn, default: []].append((event.int("seq"), id, path))
                        }
                    }
                }
            case "tool/result":
                guard let result = toolResult(from: data), !result.id.isEmpty else { continue }
                var record = tools[result.id] ?? ToolRecord(name: "", arguments: "")
                let intent = entry.dictionary("view")?.dictionary("view")
                record.resultView = intent
                record.resultTitle = intent?["title"] as? String
                record.output = result.output.isEmpty ? nil : result.output
                record.resultMeta = result.meta
                record.resultSeq = event.int("seq")
                record.settled = true
                record.isError = result.isError
                record.stopped = result.stopped
                record.errorCode = result.errorCode
                tools[result.id] = record
            case "tool/code-dispatch-start", "tool/code-dispatch":
                guard let parentId = data["parentCallId"] as? String,
                      let childId = data["subCallId"] as? String else { continue }
                var record = tools[childId] ?? ToolRecord(name: "", arguments: "")
                record.name = data["name"] as? String ?? record.name
                record.arguments = displayJSON(data["arguments"]) ?? record.arguments
                if type == "tool/code-dispatch" {
                    let output = nestedOutput(data["content"] as? [[String: Any]] ?? [])
                    record.output = output.isEmpty ? nil : output
                    record.settled = true
                    record.isError = data["isError"] as? Bool ?? false
                }
                tools[childId] = record
                if !(children[parentId] ?? []).contains(childId) { children[parentId, default: []].append(childId) }
            default: break
            }
        }

        var items: [ConversationItem] = []
        for entry in presentationEntries {
            let event = entry["event"] as? [String: Any] ?? entry
            guard let type = event["type"] as? String else { continue }
            let data = event["data"] as? [String: Any] ?? [:]
            let seq = event.int("seq")
            let turn = data.int("turn")
            let step = data.int("step")
            let timeValue = event.double("time")
            let date = timeValue > 0 ? Date(timeIntervalSince1970: timeValue / 1000) : nil
            let message = data.dictionary("message")
            let content = message?["content"] as? [[String: Any]] ?? data["content"] as? [[String: Any]] ?? []
            switch type {
            case "command/run":
                guard let id = data["commandId"] as? String, let record = commands[id] else { continue }
                if record.name == "goal" {
                    let suffix = record.args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = suffix.isEmpty ? "/goal" : "/goal \(suffix)"
                    items.append(ConversationItem(id: "command-input-\(id)", kind: .commandInput(text),
                                                  seq: record.seq, time: record.time > 0 ? Date(timeIntervalSince1970: record.time / 1_000) : nil))
                }
                let summary = record.outcomeText ?? (record.outcomeKind == nil ? "正在执行" : record.outcomeKind == "error" ? "执行失败" : "已完成")
                let body = summary.contains("\n") ? summary : nil
                items.append(ConversationItem(id: "command-\(id)",
                    kind: .command(name: record.name ?? "command", summary: summary, body: body,
                                   running: record.outcomeKind == nil, error: record.outcomeKind == "error"),
                    seq: record.seq, time: record.time > 0 ? Date(timeIntervalSince1970: record.time / 1_000) : nil))
            case "command/done":
                guard let id = data["commandId"] as? String, let record = commands[id], record.seq == seq else { continue }
                let summary = record.outcomeText ?? (record.outcomeKind == "error" ? "执行失败" : "已完成")
                items.append(ConversationItem(id: "command-\(id)",
                    kind: .command(name: record.name ?? "command", summary: summary,
                                   body: summary.contains("\n") ? summary : nil, running: false,
                                   error: record.outcomeKind == "error"), seq: seq, time: date))
            case "user/message":
                // Plugin snapshots and system reminders share role=user in
                // the durable log, but WebUI does not render them as user chat.
                guard HarnessTranscriptParsing.isVisibleUserMessage(data: data, message: message ?? [:]) else { continue }
                let text = contentText(content)
                var imageRefs: [ImageAttachmentRef] = []
                for block in content where block["type"] as? String == "image" {
                    if let ref = ImageAttachmentRef(json: block.dictionary("attachment") ?? block) {
                        imageRefs.append(ref)
                    }
                }
                if !text.isEmpty || !imageRefs.isEmpty {
                    items.append(ConversationItem(id: "user-\(seq)", kind: .user(text: text, images: imageRefs), seq: seq, time: date))
                }
            case "assistant/message":
                let messageId = message?["id"] as? String
                let actionText = content.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined()
                var index = 0
                while index < content.count {
                    let block = content[index]
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            items.append(ConversationItem(id: "assistant-step-\(turn):\(step)-\(index)", kind: .assistant(text: text, streaming: false), seq: seq, time: date, stepKey: "\(turn):\(step)"))
                        }
                    case "reasoning":
                        if let text = block["text"] as? String, !text.isEmpty {
                            items.append(ConversationItem(id: "assistant-step-\(turn):\(step)-\(index)", kind: .reasoning(text, running: false), seq: seq, time: date, stepKey: "\(turn):\(step)"))
                        }
                    case "image":
                        let start = index
                        var imageRefs: [ImageAttachmentRef] = []
                        while index < content.count, content[index]["type"] as? String == "image" {
                            if let ref = ImageAttachmentRef(json: content[index].dictionary("attachment") ?? content[index]) {
                                imageRefs.append(ref)
                            }
                            index += 1
                        }
                        if !imageRefs.isEmpty {
                            items.append(ConversationItem(id: "assistant-images-\(seq)-\(start)", kind: .images(imageRefs, alignEnd: false), seq: seq, time: date, stepKey: "\(turn):\(step)"))
                        }
                        continue
                    case "tool-call":
                        let id = block["id"] as? String ?? "call-\(seq)-\(index)"
                        let name = block["name"] as? String ?? tools[id]?.name ?? "tool"
                        let arguments = block["arguments"] as? String ?? tools[id]?.arguments ?? ""
                        let record = tools[id] ?? ToolRecord(name: name, arguments: arguments)
                        items.append(ConversationItem(id: "tool-\(id)", kind: .tool(makeTool(id: id, name: name,
                            arguments: arguments, record: record, tools: tools, children: children)), seq: seq, time: date, stepKey: "\(turn):\(step)"))
                    default: break
                    }
                    index += 1
                }
                if lastAssistantByTurn[turn] == seq, endedTurns.contains(turn) {
                    let successful = Set(tools.compactMap { id, record in record.settled && !record.isError ? id : nil })
                    var seenDiffCalls = Set<String>()
                    let editedHunks = (producedByTurn[turn] ?? []).flatMap { produced -> [DiffToolHunk] in
                        guard successful.contains(produced.callId), produced.seq <= seq,
                              seenDiffCalls.insert(produced.callId).inserted,
                              let record = tools[produced.callId] else { return [] }
                        let presentation = toolPresentation(record: record, state: .ok)
                            ?? toolPresentation(record: record, state: .running)
                        guard case let .diff(card)? = presentation else { return [] }
                        return card.diffs
                    }
                    if !editedHunks.isEmpty {
                        items.append(ConversationItem(id: "edited-\(turn)-\(seq)",
                            kind: .editedFiles(DiffToolCard(diffs: editedHunks)), seq: seq, time: date,
                            stepKey: "\(turn):\(step)"))
                    }
                    var seenCreatedPaths = Set<String>()
                    let createdPaths = editedHunks.compactMap { hunk -> String? in
                        guard hunk.oldText == nil, seenCreatedPaths.insert(hunk.path).inserted else { return nil }
                        return hunk.path
                    }
                    if !createdPaths.isEmpty {
                        items.append(ConversationItem(id: "produced-\(turn)-\(seq)", kind: .producedFiles(createdPaths), seq: seq, time: date,
                            stepKey: "\(turn):\(step)"))
                    }
                    // WebUI owns actions at the completed turn tail, not on
                    // every text block in the assistant message.
                    items.append(ConversationItem(id: "assistant-actions-\(turn)-\(seq)",
                        kind: .assistantActions(text: actionText, messageId: messageId),
                        seq: seq, time: date, stepKey: "\(turn):\(step)", metrics: turnMetrics[turn]))
                }
            case "turn/error":
                items.append(ConversationItem(id: "error-\(seq)", kind: .notice(data["message"] as? String ?? "运行出错"), seq: seq, time: date))
            case "turn/max-tokens":
                items.append(ConversationItem(id: "max-\(seq)", kind: .notice("已达到上下文长度上限"), seq: seq, time: date))
            default: break
            }
        }
        return items
    }

    private static func chunkCarriesToken(_ chunk: [String: Any]) -> Bool {
        switch chunk["type"] as? String {
        case "text-delta", "reasoning-delta": return (chunk["text"] as? String)?.isEmpty == false
        case "tool-call-delta":
            return (chunk["argumentsDelta"] as? String)?.isEmpty == false || chunk["name"] as? String != nil
        default: return false
        }
    }

    func attachment(sessionId: String, attachmentId: String, completion: @escaping (Result<Data, Error>) -> Void) {
        call("session.attachment", payload: ["sessionId": sessionId, "attachmentId": attachmentId]) { result in
            completion(result.flatMap { value in
                guard let encoded = value["data"] as? String, let data = Data(base64Encoded: encoded) else { return .failure(APIError.invalidResponse) }
                return .success(data)
            })
        }
    }

    static func parseTrajectory(_ entries: [[String: Any]]) -> [TrajectoryTurn] {
        struct PendingCall { let turn: Int; let step: Int; let name: String; let arguments: String; let seq: Int; let time: Double }
        struct Located { let turn: Int; let step: Int?; let cell: TrajectoryCell }
        let raw = entries.map { entry -> ([String: Any], [String: Any]?) in
            (entry["event"] as? [String: Any] ?? entry, entry.dictionary("view"))
        }
        var nextTurnBySeq: [Int: Int] = [:]
        var nextTurn = 1
        for (event, _) in raw.reversed() {
            let type = event["type"] as? String ?? ""
            if type == "assistant/message" || type == "turn/start" { nextTurn = max(1, event.dictionary("data")?.int("turn") ?? nextTurn) }
            nextTurnBySeq[event.int("seq")] = nextTurn
        }
        var stepStarts: [String: Double] = [:]
        var calls: [String: PendingCall] = [:]
        var locations: [Located] = []
        var index = 0
        func date(_ milliseconds: Double) -> Date? { milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil }
        func duration(_ start: Double, _ end: Double) -> TimeInterval? { start > 0 && end >= start ? (end - start) / 1000 : nil }
        func append(turn: Int, step: Int?, kind: TrajectoryKind, summary: String, detail: String, event: [String: Any],
                    start: Double? = nil, usage: TrajectoryUsage? = nil, error: Bool = false, callId: String? = nil) {
            index += 1
            let seq = event.int("seq"), end = event.double("time")
            locations.append(Located(turn: max(1, turn), step: step,
                cell: TrajectoryCell(id: callId.map { "\(kind.rawValue)-call-\($0)" } ?? "\(kind.rawValue)-seq-\(seq)",
                    index: index, kind: kind, summary: summary, detail: detail, seq: seq,
                    startedAt: date(start ?? end), duration: start.flatMap { duration($0, end) }, usage: usage,
                    isError: error, callId: callId)))
        }
        for (event, view) in raw {
            let type = event["type"] as? String ?? "", data = event.dictionary("data") ?? [:]
            let turn = data.int("turn"), step = data.int("step"), key = "\(turn):\(step)"
            switch type {
            case "request/header":
                append(turn: nextTurnBySeq[event.int("seq")] ?? 1, step: nil, kind: .system,
                    summary: "System prompt and tools", detail: displayJSON(data) ?? "", event: event)
            case "user/message":
                let message = data.dictionary("message") ?? data
                let content = message["content"] as? [[String: Any]] ?? []
                let text = contentText(content)
                let source = message.dictionary("source") ?? data.dictionary("source") ?? [:]
                let sourceKind = source["kind"] as? String ?? "unknown"
                let kind: TrajectoryKind = sourceKind == "user" ? .user : .context
                append(turn: nextTurnBySeq[event.int("seq")] ?? 1, step: nil, kind: kind,
                    summary: text.split(separator: "\n").first.map(String.init) ?? sourceKind,
                    detail: text, event: event)
            case "step/start": stepStarts[key] = event.double("time")
            case "assistant/message":
                let message = data.dictionary("message") ?? [:]
                let content = message["content"] as? [[String: Any]] ?? []
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let thinking = content.filter { $0["type"] as? String == "reasoning" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let usageRaw = data.dictionary("usage")
                let usage = usageRaw.map { TrajectoryUsage(input: $0.int("inputTokens"), output: $0.int("outputTokens"),
                    think: $0.int("reasoningTokens"), cacheRead: $0.int("cacheReadTokens"), cacheWrite: $0.int("cacheWriteTokens")) }
                let summarySource = text.isEmpty ? thinking : text
                append(turn: turn, step: step > 0 ? step : nil, kind: .assistant,
                    summary: summarySource.split(separator: "\n").first.map(String.init) ?? "Assistant response",
                    detail: [thinking.isEmpty ? nil : "THINKING\n\(thinking)", text.isEmpty ? nil : "OUTPUT\n\(text)"].compactMap { $0 }.joined(separator: "\n\n"),
                    event: event, start: stepStarts[key], usage: usage)
            case "tool/call":
                guard let id = data["callId"] as? String else { continue }
                calls[id] = PendingCall(turn: turn, step: step, name: data["name"] as? String ?? "tool",
                    arguments: data["arguments"] as? String ?? "", seq: event.int("seq"), time: event.double("time"))
            case "tool/result":
                guard let result = toolResult(from: data), let call = calls[result.id] else { continue }
                let intent = view?.dictionary("view")
                let title = intent?["title"] as? String ?? call.name
                append(turn: call.turn, step: call.step > 0 ? call.step : nil, kind: .tool,
                    summary: title, detail: "INPUT\n\(call.arguments)\n\nOUTPUT\n\(result.output)", event: event,
                    start: call.time, error: result.isError, callId: result.id)
            case "tool/code-dispatch-start":
                guard let id = data["subCallId"] as? String else { continue }
                calls[id] = PendingCall(turn: 0, step: 0, name: data["name"] as? String ?? "tool",
                    arguments: displayJSON(data["arguments"]) ?? "", seq: event.int("seq"), time: event.double("time"))
            case "tool/code-dispatch":
                guard let id = data["subCallId"] as? String, let call = calls[id] else { continue }
                let parent = data["rootCallId"] as? String
                let root = parent.flatMap { calls[$0] }
                let output = nestedOutput(data["content"] as? [[String: Any]] ?? [])
                append(turn: root?.turn ?? nextTurnBySeq[event.int("seq")] ?? 1,
                    step: (root?.step ?? 0) > 0 ? root?.step : nil, kind: .subtool,
                    summary: call.name, detail: "INPUT\n\(call.arguments)\n\nOUTPUT\n\(output)", event: event,
                    start: call.time, error: data["isError"] as? Bool ?? false, callId: id)
            default: break
            }
        }
        let turns = Dictionary(grouping: locations, by: \Located.turn).keys.sorted()
        return turns.map { turn in
            let rows = locations.filter { $0.turn == turn }
            var groupOrder: [Int?] = []
            for row in rows where !groupOrder.contains(where: { $0 == row.step }) { groupOrder.append(row.step) }
            let groups = groupOrder.map { step in
                TrajectoryGroup(turn: turn, step: step, cells: rows.filter { $0.step == step }.map(\.cell).sorted { $0.seq < $1.seq })
            }
            return TrajectoryTurn(turn: turn, groups: groups)
        }
    }

    private static func parseProjections(_ block: [String: Any]?) -> SessionProjections {
        guard let block else { return SessionProjections() }
        let values = block.dictionary("values") ?? [:]
        let todos = values.array("todos").compactMap { raw -> TodoItem? in
            guard let content = raw["content"] as? String, let status = raw["status"] as? String else { return nil }
            return TodoItem(content: content, status: status)
        }
        let goalContainer = values.dictionary("goal")
        let rawGoal = goalContainer?.dictionary("goal") ?? goalContainer
        let goal: GoalSnapshot?
        if let rawGoal, let id = rawGoal["id"] as? String,
           let objective = rawGoal["objective"] as? String, let phase = rawGoal["phase"] as? String {
            goal = GoalSnapshot(id: id, revision: rawGoal.int("revision"), objective: objective, phase: phase,
                blockedReason: rawGoal.dictionary("blockedReason")?["message"] as? String,
                maxGoalRounds: rawGoal.int("maxGoalRounds"))
        } else { goal = nil }
        let plan = values.dictionary("plan").map {
            PlanModeSnapshot(active: $0["active"] as? Bool ?? false,
                             pending: $0["pending"] as? Bool ?? false)
        }
        let permissions = parsePermissions(values.dictionary("permissions"))
        let imageLimits = ImageAttachmentLimits(json: values.dictionary("imageLimits"))
        let tokenUsage = values.dictionary("tokenUsage").map(TokenUsage.init)
        let sessionStats = values.dictionary("sessionStats").map(SessionStats.init)
        return SessionProjections(asOfSeq: block.int("asOfSeq"), todos: todos, goal: goal, plan: plan,
                                  permissions: permissions, imageLimits: imageLimits,
                                  tokenUsage: tokenUsage, sessionStats: sessionStats)
    }

    private static func parsePermissions(_ raw: [String: Any]?) -> PermissionSelectValue? {
        guard let raw, let current = raw["currentValue"] as? String else { return nil }
        let options = raw.array("options").compactMap { row -> PermissionOption? in
            guard let value = row["value"] as? String, value != "custom" else { return nil }
            return PermissionOption(value: value, name: row["name"] as? String ?? value,
                description: row["description"] as? String)
        }
        return PermissionSelectValue(options: options, currentValue: current)
    }

    static func parseQueue(_ rows: [[String: Any]]) -> [QueuedMessage] {
        rows.compactMap { raw in
            guard let id = raw["id"] as? String, let placement = raw["placement"] as? String else { return nil }
            let message = raw.dictionary("message") ?? [:]
            let messageId = message["id"] as? String ?? id
            let content = message["content"] as? [[String: Any]] ?? []
            let textParts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            let editable = textParts.count == content.count ? textParts.joined(separator: "\n") : nil
            let preview = editable ?? contentText(content)
            return QueuedMessage(id: id, messageId: messageId, placement: placement, preview: preview, text: editable)
        }
    }

    private static func contentText(_ value: [[String: Any]]) -> String {
        value.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private static func toolResult(from data: [String: Any]) -> (id: String, output: String, isError: Bool, stopped: Bool, errorCode: String?, meta: [String: Any]?)? {
        let message = data.dictionary("message")
        let source = message?.dictionary("source")
        var id = data["callId"] as? String ?? source?["callId"] as? String ?? ""
        var parts: [String] = []
        var isError = false
        for wrapper in message?["content"] as? [[String: Any]] ?? [] {
            if let value = wrapper["toolCallId"] as? String { id = value }
            isError = isError || (wrapper["isError"] as? Bool ?? false)
            for block in wrapper["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text", let text = block["text"] as? String { parts.append(text) }
                else if let encoded = try? JSONSerialization.data(withJSONObject: block, options: [.prettyPrinted]),
                        let text = String(data: encoded, encoding: .utf8) { parts.append(text) }
            }
        }
        if parts.isEmpty { parts.append(contentText(data["content"] as? [[String: Any]] ?? [])) }
        let error = data.dictionary("error")
        let errorCode = error?["code"] as? String
        if parts.allSatisfy(\.isEmpty), let errorCode {
            parts.append("\(error?["name"] as? String ?? "Error"): \(errorCode)")
        }
        let output = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        return (id, output, isError, errorCode == "interrupted" || errorCode == "ASK_ABORTED", errorCode,
                data.dictionary("meta") ?? message?.dictionary("meta"))
    }

    private static func makeTool(id: String, name: String, arguments: String, record: ToolRecord,
                                 tools: [String: ToolRecord], children: [String: [String]], ancestors: Set<String> = []) -> ToolCall {
        let variant = classifyTool(name)
        let derived = summaryForTool(name: name, arguments: arguments, fallback: id)
        var state: ToolState = record.stopped ? .stopped : record.isError ? .error : record.settled ? .ok : .running
        let parsed = parseArguments(arguments)
        let path: String? = [.read, .write, .edit].contains(variant)
            ? (parsed?["path"] as? String ?? parsed?["file_path"] as? String)
            : nil
        let presentation = toolPresentation(record: record, state: state)
        var summary: String
        var summarySuffix: String?
        switch presentation {
        case let .terminal(card): summary = card.description?.isEmpty == false ? card.description! : derived
        case let .search(card): summary = card.title?.isEmpty == false ? card.title! : derived
        case let .diff(card):
            summary = derived
            summarySuffix = card.changeSummary
        default: summary = derived
        }
        if name == "todo_write", let todo = todoSummary(arguments) {
            summary = todo.text
            summarySuffix = todo.extra > 0 ? "+\(todo.extra)" : nil
        } else if name == "ask_user_question" {
            if record.errorCode == "ASK_CANCELLED" { summary = "已取消" }
            else if record.errorCode == "ASK_ABORTED" { summary = "已中断" }
            else if !record.settled { summary = "等待回答" }
            else if !record.isError, let answered = answeredQuestionSummary(record.output) { summary = answered }
        } else if name == "skill", let value = parsed?["name"] as? String, !value.isEmpty {
            summary = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        } else if name.hasPrefix("cordis_") {
            let keys = name == "cordis_define" ? ["name"] : ["pluginId", "id", "packageId"]
            if let value = keys.lazy.compactMap({ parsed?[$0] as? String }).first(where: { !$0.isEmpty }) {
                summary = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
            }
        }
        if case let .terminal(terminal) = presentation, !terminal.running,
           (terminal.signal != nil || (terminal.exitCode != nil && terminal.exitCode != 0)) { state = .error }
        let card = state == .running ? record.callView?["card"] as? String : record.resultView?["card"] as? String
        let cordis = CordisCardModel.make(name: name, callId: id, argsRaw: arguments,
            output: record.output, resultMeta: record.resultMeta, resultSeq: record.resultSeq, state: state)
        return ToolCall(id: id, name: name, arguments: arguments,
                        title: toolTitle(name: name, variant: variant), summary: summary,
                        rawInput: record.rawInput, output: record.output, variant: variant,
                        state: state, errorCode: record.errorCode, summarySuffix: summarySuffix,
                        card: card, filePath: path, presentation: presentation, cordis: cordis,
                        subCalls: ancestors.count >= 256 ? [] : (children[id] ?? []).compactMap { childId in
                            guard childId != id, !ancestors.contains(childId), let child = tools[childId] else { return nil }
                            return makeTool(id: childId, name: child.name, arguments: child.arguments,
                                record: child, tools: tools, children: children, ancestors: ancestors.union([id]))
                        })
    }

    private static func todoSummary(_ arguments: String) -> (text: String, extra: Int)? {
        guard let parsed = parseArguments(arguments), let rawTodos = parsed["todos"] as? [[String: Any]] else { return nil }
        let done = rawTodos.filter { $0["status"] as? String == "completed" }.count
        let active = rawTodos.filter { $0["status"] as? String == "in_progress" }
        let head = "\(done)/\(rawTodos.count) 已完成"
        guard let content = active.first?["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (head, 0) }
        return ("\(head) · \(content)", max(0, active.count - 1))
    }

    private static func answeredQuestionSummary(_ output: String?) -> String? {
        guard let output, let data = output.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = parsed["answers"] as? [[String: Any]] else { return nil }
        let answered = answers.filter { answer in
            if let selected = answer["selected"] as? [Any], !selected.isEmpty { return true }
            if let custom = answer["custom"] as? String, !custom.isEmpty { return true }
            return false
        }.count
        return "\(answered)/\(answers.count) 已回答"
    }

    private static func nestedOutput(_ content: [[String: Any]]) -> String {
        content.compactMap { block -> String? in
            if block["type"] as? String == "text" { return block["text"] as? String }
            guard let data = try? JSONSerialization.data(withJSONObject: block, options: [.prettyPrinted]) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
    }

    private static func toolPresentation(record: ToolRecord, state: ToolState) -> ToolPresentation? {
        let running = state == .running
        if running, let view = record.callView, view["card"] as? String == "terminal",
           let title = view["title"] as? String {
            return .terminal(TerminalToolCard(command: title, cwd: view["cwd"] as? String,
                usesSessionCwd: (view["cwd"] as? String)?.isEmpty != false,
                description: view["description"] as? String, output: nil, exitCode: nil,
                signal: nil, running: true))
        }
        if !running, let result = record.resultView, result["card"] as? String == "terminal" {
            let hasCall = record.callView?["card"] as? String == "terminal"
            let command = result["title"] as? String ?? record.callView?["title"] as? String ?? record.callTitle ?? ""
            return .terminal(TerminalToolCard(command: command,
                cwd: hasCall ? record.callView?["cwd"] as? String : nil,
                usesSessionCwd: hasCall && (record.callView?["cwd"] as? String)?.isEmpty != false,
                description: record.callView?["description"] as? String,
                output: result["output"] as? String, exitCode: optionalInt(result["exitCode"]),
                signal: result["signal"] as? String, running: false))
        }

        let diffView: [String: Any]? = running
            ? (record.callView?["card"] as? String == "diff" ? record.callView : nil)
            : (record.resultView?["card"] as? String == "diff" ? record.resultView : nil)
        if let diffView, let rows = diffView["diffs"] as? [[String: Any]], !rows.isEmpty {
            var hunks: [DiffToolHunk] = []
            for row in rows {
                guard let path = row["path"] as? String, let newText = row["newText"] as? String else { return nil }
                let oldValue = row["oldText"]
                guard oldValue == nil || oldValue is NSNull || oldValue is String else { return nil }
                hunks.append(DiffToolHunk(path: path, oldText: oldValue as? String, newText: newText))
            }
            return .diff(DiffToolCard(diffs: hunks))
        }

        guard !running, let result = record.resultView, let card = result["card"] as? String else { return nil }
        if card == "read", let path = result["path"] as? String,
           let rawLines = result["lines"] as? [[String: Any]], optionalInt(result["totalLines"]) != nil {
            var lines: [ReadToolLine] = []
            for line in rawLines {
                guard let number = optionalInt(line["number"]), let text = line["text"] as? String else { return nil }
                lines.append(ReadToolLine(number: number, text: text))
            }
            return .read(ReadToolCard(label: result["title"] as? String, path: path, lines: lines,
                totalLines: optionalInt(result["totalLines"])!, language: result["lang"] as? String))
        }
        if card == "search", let shape = result["shape"] as? String,
           let truncated = result["truncated"] as? Bool, let total = optionalInt(result["total"]) {
            let content: SearchToolContent
            if shape == "paths", let paths = result["paths"] as? [String] {
                content = .paths(paths)
            } else if shape == "matches", let rawFiles = result["files"] as? [[String: Any]] {
                var files: [SearchToolFile] = []
                for rawFile in rawFiles {
                    guard let path = rawFile["path"] as? String,
                          let rawMatches = rawFile["matches"] as? [[String: Any]] else { return nil }
                    var matches: [SearchToolMatch] = []
                    for rawMatch in rawMatches {
                        guard let number = optionalInt(rawMatch["lineNumber"]),
                              let line = rawMatch["line"] as? String else { return nil }
                        matches.append(SearchToolMatch(lineNumber: number, line: line))
                    }
                    files.append(SearchToolFile(path: path, matches: matches))
                }
                content = .matches(files)
            } else { return nil }
            return .search(SearchToolCard(title: result["title"] as? String, content: content, truncated: truncated, total: total,
                recovery: truncated ? record.output : nil))
        }
        if card == "web", let kind = result["kind"] as? String,
           let truncated = result["truncated"] as? Bool {
            if kind == "fetch", let url = result["url"] as? String,
               let status = optionalInt(result["statusCode"]) {
                return .web(.fetch(url: url, statusCode: status, truncated: truncated))
            }
            if kind == "search", let rawSources = result["sources"] as? [[String: Any]] {
                var sources: [WebToolSource] = []
                for source in rawSources {
                    guard let url = source["url"] as? String else { return nil }
                    sources.append(WebToolSource(url: url, title: source["title"] as? String,
                        snippet: source["snippet"] as? String, publishedAt: source["publishedAt"] as? String))
                }
                return .web(.search(answer: result["answer"] as? String, sources: sources, truncated: truncated))
            }
        }
        return nil
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func cordisInventoryRow(_ raw: [String: Any]) -> CordisInventoryRow? {
        guard let pluginId = raw["pluginId"] as? String, !pluginId.isEmpty,
              let agentId = raw["agentId"] as? String else { return nil }
        let packages = (raw["packages"] as? [[String: Any]] ?? []).compactMap { package -> CordisInventoryPackage? in
            guard let packageId = package["packageId"] as? String else { return nil }
            return CordisInventoryPackage(packageId: packageId, name: package["name"] as? String ?? packageId,
                purpose: package["purpose"] as? String ?? "", hasHostHalf: package["hasHostHalf"] as? Bool ?? false,
                hasClientHalf: package["hasClientHalf"] as? Bool ?? false)
        }
        let active = raw.dictionary("activeRun")
        let attempt = raw.dictionary("latestRun").flatMap { latest -> CordisRunAttempt? in
            guard let runId = latest["pluginRunId"] as? String,
                  let packageId = latest["packageId"] as? String,
                  let mode = latest["mode"] as? String,
                  let status = latest["status"] as? String else { return nil }
            return CordisRunAttempt(pluginRunId: runId, packageId: packageId, mode: mode, status: status,
                requiresApproval: latest["requiresApproval"] as? Bool ?? false,
                approvalRequestId: latest["approvalRequestId"] as? String,
                errorMessage: latest.dictionary("error")?["message"] as? String)
        }
        return CordisInventoryRow(pluginId: pluginId, agentId: agentId, packages: packages,
            currentPackageId: raw["currentPackageId"] as? String, nextPackageId: raw["nextPackageId"] as? String,
            activeRunId: active?["pluginRunId"] as? String, activePackageId: active?["packageId"] as? String,
            latestRun: attempt)
    }

    private static func displayJSON(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return value }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return String(describing: value) }
        return String(data: data, encoding: .utf8)
    }

    private static func classifyTool(_ name: String) -> ToolVariant {
        switch name {
        case "bash", "pwsh": return .bash
        case "read", "web_fetch", "cordis_package_inspect", "cordis_runtime_inspect": return .read
        case "web_search", "grep", "glob": return .search
        case "write": return .write
        case "edit": return .edit
        case "run_code": return .code
        default: return .others
        }
    }

    private static func toolTitle(name: String, variant: ToolVariant) -> String {
        switch name {
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "web_fetch": return "Fetch"
        case "pwsh": return "Pwsh"
        case "cordis_package_inspect", "cordis_runtime_inspect": return "Inspect"
        case "cordis_run": return "Run Cordis Plugin"
        case "cordis_stop": return "Stop Cordis Plugin"
        case "cordis_undefine": return "Remove Cordis Plugin"
        default: break
        }
        switch variant { case .search: return "Search"; case .read: return "Read"; case .bash: return "Bash"
        case .write: return "Write"; case .edit: return "Edit"; case .code: return "Code"; case .others: return "Tool call" }
    }

    private static func parseArguments(_ arguments: String) -> [String: Any]? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func summaryForTool(name: String, arguments: String, fallback: String) -> String {
        let variant = classifyTool(name)
        let keys: [String]
        switch variant {
        case .bash: keys = ["description", "command"]
        case .read: keys = ["path", "file_path", "url"]
        case .search: keys = ["query", "pattern", "url"]
        case .write, .edit: keys = ["path", "file_path"]
        case .code: keys = ["description"]
        case .others: keys = []
        }
        let firstLine: (String) -> String = { value in
            value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        }
        var base = arguments.isEmpty ? fallback : firstLine(arguments)
        if let json = parseArguments(arguments) {
            if let value = keys.lazy.compactMap({ json[$0] as? String }).first(where: { !$0.isEmpty }) {
                base = firstLine(value)
            } else if let value = json.values.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) {
                base = firstLine(value)
            }
        }
        let ownsTitle = ["cordis_run", "cordis_stop", "cordis_undefine"].contains(name)
        if variant == .others, !name.isEmpty, !ownsTitle { return "\(name) · \(base)" }
        return base
    }
}
