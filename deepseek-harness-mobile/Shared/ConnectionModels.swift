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

enum MobileMessageRole: Equatable { case user, assistant, reasoning, activity, notice }

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
