import Foundation

enum ServerKind: String, Codable, CaseIterable, Identifiable {
    case localHost
    case encryptedRelay

    var id: String { rawValue }
    var title: String { self == .localHost ? "本地 Host" : "加密服务端" }
    var subtitle: String {
        self == .localHost ? "同一局域网内直接连接 Harness" : "通过端到端加密中继连接你的 Mac"
    }
}

struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ServerKind
    var baseURL: URL

    static let localDefault = ServerProfile(name: "本机", kind: .localHost, baseURL: URL(string: "http://localhost:3080")!)
}

@MainActor
final class ServerProfileStore: ObservableObject {
    @Published var profiles: [ServerProfile] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }

    var selected: ServerProfile {
        profiles.first(where: { $0.id == selectedID }) ?? profiles[0]
    }

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: "mobile.serverProfiles"),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data), !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = [.localDefault]
        }
        selectedID = defaults.string(forKey: "mobile.selectedServer").flatMap(UUID.init(uuidString:)) ?? profiles.first?.id
    }

    func add(name: String, kind: ServerKind, url: URL) {
        let profile = ServerProfile(name: name, kind: kind, baseURL: url)
        profiles.append(profile)
        selectedID = profile.id
    }

    func update(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }

    func remove(_ profile: ServerProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if selectedID == profile.id { selectedID = profiles.first?.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "mobile.serverProfiles") }
        UserDefaults.standard.set(selectedID?.uuidString, forKey: "mobile.selectedServer")
    }
}

struct MobileSession: Identifiable, Hashable {
    let id: String
    let title: String
    let updatedAt: Date
    let running: Bool
    let cwd: String?
    let permission: String
    let blank: Bool
    let todos: [MobileTodoItem]
    let goal: MobileGoalSnapshot?
    let plan: MobilePlanSnapshot?

    init?(json: [String: Any]) {
        guard let id = json["sessionId"] as? String else { return nil }
        self.id = id
        let projections = (json["projections"] as? [String: Any])?["values"] as? [String: Any]
        let projectedTitle = projections?["title"] as? String
        let permissions = projections?["permissions"] as? [String: Any]
        cwd = json["cwd"] as? String
        permission = permissions?["currentValue"] as? String ?? "workspace-write"
        blank = json["blank"] as? Bool ?? false
        todos = (projections?["todos"] as? [[String: Any]] ?? []).compactMap(MobileTodoItem.init)
        let goalContainer = projections?["goal"] as? [String: Any]
        goal = MobileGoalSnapshot(json: goalContainer?["goal"] as? [String: Any] ?? goalContainer)
        plan = (projections?["plan"] as? [String: Any]).map(MobilePlanSnapshot.init)
        title = projectedTitle?.isEmpty == false ? projectedTitle! : cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "新会话"
        updatedAt = Date(timeIntervalSince1970: ((json["updatedAt"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        running = json["running"] as? Bool ?? false
    }
}

struct MobileSubagentEntry: Identifiable, Hashable {
    let id: String
    let mode: String
    let activity: String
    let hasChildren: Bool
    let label: String?
    let diagnostic: String?
    let durationMs: Int?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        if json["kind"] as? String == "diagnostic" {
            mode = ""
            activity = "inactive"
            hasChildren = false
            label = nil
            diagnostic = json["reason"] as? String ?? "子代理记录暂不可用"
            durationMs = nil
        } else {
            mode = json["mode"] as? String ?? "one-shot"
            activity = json["activity"] as? String ?? "inactive"
            hasChildren = json["hasChildren"] as? Bool ?? false
            label = json["label"] as? String
            diagnostic = nil
            durationMs = (json["durationMs"] as? NSNumber)?.intValue
        }
    }

    var isDiagnostic: Bool { diagnostic != nil }
    var displayName: String { label?.isEmpty == false ? label! : id }
}

struct MobileSubagentNavigation: Identifiable, Hashable {
    let parentID: String
    let entry: MobileSubagentEntry
    var id: String { entry.id }
}

struct MobileBackgroundJob: Identifiable, Hashable {
    let id: String
    let kind: String
    let label: String
    let status: String
    let detail: String?
    let startedAt: Date
    let finishedAt: Date?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let kind = json["kind"] as? String,
              let label = json["label"] as? String,
              let status = json["status"] as? String else { return nil }
        self.id = id
        self.kind = kind
        self.label = label
        self.status = status
        detail = json["detail"] as? String
        let started = (json["startedAt"] as? NSNumber)?.doubleValue ?? 0
        let finished = (json["finishedAt"] as? NSNumber)?.doubleValue
        startedAt = Date(timeIntervalSince1970: started / 1_000)
        finishedAt = finished.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    var isLive: Bool { status == "running" || status == "stopping" }
}

struct MobileApprovalRequest: Identifiable, Hashable {
    let rpcID: String
    let sessionID: String
    let approvalID: String
    let toolName: String
    let callID: String?
    let reason: String?
    var id: String { approvalID }
}

enum MobileDraftAttachmentKind: String, Hashable { case image, textFile }

struct MobileDraftAttachment: Identifiable, Hashable {
    let id: UUID
    let kind: MobileDraftAttachmentKind
    let name: String
    let mediaType: String
    let data: Data

    var byteCountText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    func promptBlock() -> [String: Any]? {
        switch kind {
        case .image:
            return ["type": "image", "mediaType": mediaType,
                    "data": data.base64EncodedString(), "name": name]
        case .textFile:
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let escapedName = name.replacingOccurrences(of: "\"", with: "&quot;")
            return ["type": "text", "text": "<attached_file name=\"\(escapedName)\" media_type=\"\(mediaType)\">\n\(text)\n</attached_file>"]
        }
    }
}

struct MobileTodoItem: Identifiable, Hashable {
    let content: String
    let status: String
    var id: String { "\(status):\(content)" }

    init?(json: [String: Any]) {
        guard let content = json["content"] as? String,
              let status = json["status"] as? String else { return nil }
        self.content = content
        self.status = status
    }
}

struct MobileGoalSnapshot: Identifiable, Hashable {
    let id: String
    let revision: Int
    let objective: String
    let phase: String
    let blockedReason: String?
    let maxGoalRounds: Int

    init?(json: [String: Any]?) {
        guard let json, let id = json["id"] as? String,
              let objective = json["objective"] as? String,
              let phase = json["phase"] as? String else { return nil }
        self.id = id
        revision = (json["revision"] as? NSNumber)?.intValue ?? 0
        self.objective = objective
        self.phase = phase
        blockedReason = (json["blockedReason"] as? [String: Any])?["message"] as? String
        maxGoalRounds = (json["maxGoalRounds"] as? NSNumber)?.intValue ?? 0
    }
}

struct MobilePlanSnapshot: Hashable {
    let active: Bool
    let pending: Bool
    var targetActive: Bool { pending ? !active : active }

    init(json: [String: Any]) {
        active = json["active"] as? Bool ?? false
        pending = json["pending"] as? Bool ?? false
    }
}

struct MobileWorkspace: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let sessionIDs: [String]

    init?(json: [String: Any]) {
        guard let id = json["workspaceId"] as? String ?? json["id"] as? String,
              let path = json["path"] as? String ?? json["cwd"] as? String else { return nil }
        self.id = id
        self.path = path
        let title = json["title"] as? String
        name = title?.isEmpty == false ? title! : URL(fileURLWithPath: path).lastPathComponent
        sessionIDs = json["sessionIds"] as? [String] ?? []
    }
}

struct MobileReasoningEffort: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
}

struct MobileModelChoice: Identifiable, Hashable {
    let provider: String
    let providerName: String
    let id: String
    let name: String
    let description: String?
    let efforts: [MobileReasoningEffort]
    let defaultEffort: String?

    var key: String { "\(provider)/\(id)" }
}

struct MobileModelSelection: Hashable {
    let provider: String
    let model: String
    let reasoningEffort: String?

    var key: String { "\(provider)/\(model)" }
}

enum MobileMessageRole: Equatable { case user, assistant, reasoning, activity, command, files, notice }

struct MobileQueuedMessage: Identifiable, Hashable {
    let id: String
    let messageID: String
    let placement: String
    let preview: String
    let text: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let placement = json["placement"] as? String else { return nil }
        self.id = id
        self.placement = placement
        let message = json["message"] as? [String: Any] ?? [:]
        messageID = message["id"] as? String ?? id
        let content = message["content"] as? [[String: Any]] ?? []
        let textParts = content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
        text = textParts.count == content.count ? textParts.joined(separator: "\n") : nil
        preview = text ?? textParts.joined(separator: "\n")
    }
}

struct MobileDiffHunk {
    let path: String
    let oldText: String?
    let newText: String
}

struct MobileMessage: Identifiable {
    let id: String
    let role: MobileMessageRole
    let text: String
    let time: Date?
    var detail: String? = nil
    var isError = false
    var toolName: String? = nil
    var running = false
    var toolSummary: String? = nil
    var toolInput: String? = nil
    var toolOutput: String? = nil
    var toolErrorCode: String? = nil
    var toolChildren: [MobileMessage] = []
    var toolDiffs: [MobileDiffHunk] = []
}

struct RelayCredential: Codable {
    let vaultId: String
    let deviceId: String
    let accessToken: String
    let vaultKey: Data
}
