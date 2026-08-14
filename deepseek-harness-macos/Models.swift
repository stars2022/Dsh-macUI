import Foundation

struct TokenUsage: Hashable {
    let uncachedInput: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    init(json: [String: Any]) {
        uncachedInput = json.int("uncachedInputTokens")
        output = json.int("outputTokens")
        cacheRead = json.int("cacheReadTokens")
        cacheWrite = json.int("cacheWriteTokens")
    }
}

/// Durable whole-session timing/count projection from the Host's
/// `sessionStats` unit. Values are milliseconds and survive paging and
/// compaction, matching the WebUI stats strip contract.
struct SessionStats: Hashable {
    let turns: Int
    let steps: Int
    let llmMs: Double
    let toolMs: Double
    let ttftMs: Double
    let ttftSteps: Int
    let decodeMs: Double
    let decodeTokens: Int

    init(turns: Int, steps: Int, llmMs: Double, toolMs: Double,
         ttftMs: Double, ttftSteps: Int, decodeMs: Double, decodeTokens: Int) {
        self.turns = turns
        self.steps = steps
        self.llmMs = llmMs
        self.toolMs = toolMs
        self.ttftMs = ttftMs
        self.ttftSteps = ttftSteps
        self.decodeMs = decodeMs
        self.decodeTokens = decodeTokens
    }

    init(json: [String: Any]) {
        turns = json.int("turns")
        steps = json.int("steps")
        llmMs = json.double("llmMs")
        toolMs = json.double("toolMs")
        ttftMs = json.double("ttftMs")
        ttftSteps = json.int("ttftSteps")
        decodeMs = json.double("decodeMs")
        decodeTokens = json.int("decodeTokens")
    }
}

struct ContextPressure: Hashable {
    let pressureTokens: Int
    let projectedTokens: Int
    let contextWindow: Int

    init?(json: [String: Any]?) {
        guard let json, json.int("contextWindow") > 0 else { return nil }
        pressureTokens = json.int("pressureTokens")
        projectedTokens = json.int("projectedTokens")
        contextWindow = json.int("contextWindow")
    }

    var usedTokens: Int { max(pressureTokens, projectedTokens) }
    var fraction: Double { min(1, max(0, Double(usedTokens) / Double(contextWindow))) }
}

struct ContextBreakdown: Hashable {
    let system: Int
    let tools: Int
    let messages: Int

    init(json: [String: Any]) {
        system = json.int("systemTokens")
        tools = json.int("toolsTokens")
        messages = json.int("messageTokens")
    }
}

struct SessionSummary: Hashable {
    let id: String
    let updatedAt: Date
    let running: Bool
    let blank: Bool
    let cwd: String?
    let preset: String?
    let title: String?
    let permission: String?
    let contextPressure: ContextPressure?
    let contextBreakdown: ContextBreakdown?
    let tokenUsage: TokenUsage?
    let parentSessionId: String?
    let origin: String?

    init?(json: [String: Any]) {
        guard let id = json["sessionId"] as? String else { return nil }
        self.id = id
        updatedAt = Date(timeIntervalSince1970: json.double("updatedAt") / 1000)
        running = json["running"] as? Bool ?? false
        blank = json["blank"] as? Bool ?? false
        cwd = json["cwd"] as? String
        preset = json["agentPreset"] as? String
        let values = json.dictionary("projections")?.dictionary("values") ?? [:]
        title = values["title"] as? String
        permission = values.dictionary("permissions")?["currentValue"] as? String
        contextPressure = ContextPressure(json: values.dictionary("contextPressure"))
        contextBreakdown = values.dictionary("contextBreakdown").map(ContextBreakdown.init)
        tokenUsage = values.dictionary("tokenUsage").map(TokenUsage.init)
        parentSessionId = json["parentSessionId"] as? String ?? json["parentId"] as? String
        origin = json["origin"] as? String
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if blank { return "新会话" }
        if let cwd { return URL(fileURLWithPath: cwd).lastPathComponent }
        return "未命名会话"
    }

    func withRunning(_ running: Bool, blank: Bool? = nil, updatedAt: Date? = nil) -> SessionSummary {
        SessionSummary(id: id, updatedAt: updatedAt ?? self.updatedAt, running: running,
                       blank: blank ?? self.blank, cwd: cwd, preset: preset, title: title,
                       permission: permission, contextPressure: contextPressure,
                       contextBreakdown: contextBreakdown, tokenUsage: tokenUsage,
                       parentSessionId: parentSessionId, origin: origin)

    }

    private init(id: String, updatedAt: Date, running: Bool, blank: Bool, cwd: String?, preset: String?,
                 title: String?, permission: String?, contextPressure: ContextPressure?,
                 contextBreakdown: ContextBreakdown?, tokenUsage: TokenUsage?, parentSessionId: String? = nil, origin: String? = nil) {
        self.id = id; self.updatedAt = updatedAt; self.running = running; self.blank = blank
        self.cwd = cwd; self.preset = preset; self.title = title; self.permission = permission
        self.contextPressure = contextPressure; self.contextBreakdown = contextBreakdown; self.tokenUsage = tokenUsage
        self.parentSessionId = parentSessionId; self.origin = origin
    }
}

struct SubagentEntry: Hashable, Identifiable {
    let id: String
    let mode: String
    let activity: String
    let hasChildren: Bool
    let label: String?
    let diagnostic: String?
    let tokenUsage: TokenUsage?
    let durationMs: Int?
    var isDiagnostic: Bool { diagnostic != nil }
}

struct AgentPresetEntry: Hashable, Identifiable {
    let id: String
    let trust: String
    let isDefault: Bool
    let name: String?
    let description: String?
    let broken: String?
    var displayName: String { name?.isEmpty == false ? name! : id }
}

struct PluginInventoryEntry: Hashable, Identifiable {
    let entryId: String
    let moduleName: String
    let enabled: Bool
    let fiberPhase: String?
    var id: String { entryId }

    var shortName: String {
        var value = moduleName
        if value.hasPrefix("@"), let slash = value.firstIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        for prefix in ["cordis:", "cordis-plugin-", "dsh-host-", "dsh-client-", "dsh-"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            break
        }
        return value
    }
}

struct CordisInventoryPackage: Hashable, Identifiable {
    let packageId: String
    let name: String
    let purpose: String
    let hasHostHalf: Bool
    let hasClientHalf: Bool
    var id: String { packageId }
}

struct CordisRunAttempt: Hashable {
    let pluginRunId: String
    let packageId: String
    let mode: String
    let status: String
    let requiresApproval: Bool
    let approvalRequestId: String?
    let errorMessage: String?
}

struct CordisInventoryRow: Hashable, Identifiable {
    let pluginId: String
    let agentId: String
    let packages: [CordisInventoryPackage]
    let currentPackageId: String?
    let nextPackageId: String?
    let activeRunId: String?
    let activePackageId: String?
    let latestRun: CordisRunAttempt?
    var id: String { pluginId }
}

struct CredentialStatus: Hashable {
    let configured: Bool
    let source: String?
    let writable: Bool
}

struct SettingsNamespaceSnapshot: Identifiable {
    let ns: String
    let value: [String: Any]
    let base: [String: Any]
    let user: [String: Any]
    let revision: Int
    let applies: String
    var id: String { ns }

    func value(_ key: String) -> Any? { value[key] }
    func baseValue(_ key: String) -> Any? { base[key] }
    func isOverridden(_ key: String) -> Bool { user[key] != nil }
}

struct PluginSettingsSnapshot {
    let namespaces: [SettingsNamespaceSnapshot]
    let writable: Bool
    let webSearchCredential: CredentialStatus?

    func namespace(_ name: String) -> SettingsNamespaceSnapshot? {
        namespaces.first { $0.ns == name }
    }
}

struct HostSettingsSnapshot {
    let namespaces: [SettingsNamespaceSnapshot]
    let writable: Bool
    let hasDocument: Bool

    func namespace(_ name: String) -> SettingsNamespaceSnapshot? {
        namespaces.first { $0.ns == name }
    }
}

struct ModelProviderSettings: Identifiable {
    let id: String
    let displayName: String
    let settingsNamespace: String
    let settingsPath: [String]
    let active: Bool
    let declared: Bool?
    let configured: Bool
    let removable: Bool
    let apiKeyRef: String?
    let credential: CredentialStatus?
    let profile: [String: Any]
    let revision: Int
    let applies: String

    var modelCount: Int { (profile["models"] as? [[String: Any]])?.count ?? 0 }
    var usable: Bool { active && (apiKeyRef == nil || credential?.configured == true) }
    var credentialRef: String {
        if let apiKeyRef, !apiKeyRef.isEmpty { return apiKeyRef }
        let stem = id.uppercased().replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression)
        return "\(stem)_API_KEY"
    }
}

struct WorkspaceSummary: Hashable, Identifiable {
    let id: String
    let name: String
    let path: String
    let sessionIds: [String]
    let createdAt: Date
    let updatedAt: Date

    init?(json: [String: Any]) {
        guard let id = json["workspaceId"] as? String ?? json["id"] as? String else { return nil }
        self.id = id
        guard let path = json["path"] as? String ?? json["cwd"] as? String else { return nil }
        self.path = path
        name = json["title"] as? String ?? json["name"] as? String ?? URL(fileURLWithPath: path).lastPathComponent
        sessionIds = json["sessionIds"] as? [String] ?? []
        let created = (json["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let updated = (json["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        createdAt = created ?? Date.distantPast
        updatedAt = updated ?? createdAt
    }
}

struct SessionSearchHit: Hashable, Identifiable {
    let sessionId: String
    let snippet: String
    var id: String { sessionId }
}

enum SessionGroupMode: String, CaseIterable {
    case workspace
    case flat
}

enum SessionOrderMode: String, CaseIterable {
    case manual
    case updated
}

struct MessageFeedbackItem: Hashable {
    let messageId: String
    let rating: String
    let note: String?
    let version: String
}

struct ReasoningEffort: Hashable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

struct ModelChoice: Hashable, Identifiable {
    let provider: String
    let providerName: String
    let id: String
    let name: String
    let description: String?
    let efforts: [ReasoningEffort]
    let defaultEffort: String?

    var key: String { "\(provider)/\(id)" }
}

struct ModelSelection: Hashable {
    let provider: String
    let model: String
    let reasoningEffort: String?
    var key: String { "\(provider)/\(model)" }
}

struct ModelCatalogFailure: Hashable, Identifiable {
    let id: String
    let name: String
    let message: String
}

struct ModelCatalogSnapshot {
    let current: ModelSelection
    let choices: [ModelChoice]
    let failures: [ModelCatalogFailure]
    let routable: Bool
}

enum ToolVariant: String, Hashable {
    case search, read, bash, write, edit, code, others
}

enum ToolState: String, Hashable {
    case running, ok, error, stopped
}

struct TerminalToolCard: Hashable {
    let command: String
    let cwd: String?
    let usesSessionCwd: Bool
    let description: String?
    let output: String?
    let exitCode: Int?
    let signal: String?
    let running: Bool
}

struct ReadToolLine: Hashable, Identifiable {
    let number: Int
    let text: String
    var id: Int { number }
}

struct ReadToolCard: Hashable {
    let label: String?
    let path: String
    let lines: [ReadToolLine]
    let totalLines: Int
    let language: String?
}

struct SearchToolMatch: Hashable {
    let lineNumber: Int
    let line: String
}

struct SearchToolFile: Hashable {
    let path: String
    let matches: [SearchToolMatch]
}

enum SearchToolContent: Hashable {
    case matches([SearchToolFile])
    case paths([String])
}

struct SearchToolCard: Hashable {
    let title: String?
    let content: SearchToolContent
    let truncated: Bool
    let total: Int
    let recovery: String?
}

struct DiffToolHunk: Hashable {
    let path: String
    let oldText: String?
    let newText: String
}

struct DiffToolCard: Hashable {
    let diffs: [DiffToolHunk]

    var additions: Int { diffs.reduce(0) { $0 + Self.lineCount($1.newText) } }
    var deletions: Int { diffs.reduce(0) { $0 + ($1.oldText.map(Self.lineCount) ?? 0) } }
    var fileCount: Int { Set(diffs.map(\.path)).count }
    var changeSummary: String { "+\(additions) -\(deletions)" }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

struct WebToolSource: Hashable, Identifiable {
    let url: String
    let title: String?
    let snippet: String?
    let publishedAt: String?
    var id: String { url }
}

enum WebToolCard: Hashable {
    case search(answer: String?, sources: [WebToolSource], truncated: Bool)
    case fetch(url: String, statusCode: Int, truncated: Bool)
}

enum ToolPresentation: Hashable {
    case terminal(TerminalToolCard)
    case read(ReadToolCard)
    case search(SearchToolCard)
    case diff(DiffToolCard)
    case web(WebToolCard)
}

struct ToolCall: Hashable, Identifiable {
    let id: String
    let name: String
    let arguments: String
    let title: String
    let summary: String
    let rawInput: String?
    let output: String?
    let variant: ToolVariant
    let state: ToolState
    let errorCode: String?
    let summarySuffix: String?
    let card: String?
    let filePath: String?
    let presentation: ToolPresentation?
    let cordis: CordisCard?
    let subCalls: [ToolCall]

    var displayTitle: String {
        if name == "todo_write" { return "更新任务清单" }
        if name == "ask_user_question" { return "提问" }
        if name == "skill" { return "Skill" }
        if name == "cordis_define" { return "注册 Cordis 插件" }
        if name == "cordis_run" {
            if let data = arguments.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["mode"] as? String == "update" { return "更新 Cordis 插件" }
            return "运行 Cordis 插件"
        }
        if name == "cordis_stop" { return "停止 Cordis 插件" }
        if name == "cordis_undefine" { return "移除 Cordis 插件" }
        // WebUI `toolRowModel` keeps the variant/tool-owned title stable
        // across running, ok, error and stopped. Lifecycle is represented by
        // the sweep/state dot and the summary, never by replacing the title.
        return title
    }

    var errorSummary: String? {
        if name == "ask_user_question" {
            if errorCode == "ASK_CANCELLED" { return nil }
            if errorCode == "ASK_ABORTED" { return nil }
        }
        guard state == .error, let output, !output.isEmpty else { return nil }
        return output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    var expandable: Bool {
        if case let .define(card) = cordis { return card.hostCode != nil || card.clientCode != nil || card.output != nil }
        if cordis != nil { return false }
        if presentation != nil { return true }
        // Code-dispatched commands do not carry Host presentation views yet.
        // They still use WebUI's generic IN/OUT fallback, so their own command
        // arguments and result stay expandable together after the synthetic
        // outer Code row is removed by the concise transcript projection.
        if output != nil { return true }
        return !(rawInput ?? arguments).isEmpty
    }

    var inputText: String? {
        let source = rawInput ?? arguments
        guard !source.isEmpty else { return nil }
        if variant == .code,
           let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = object["code"] as? String, !code.isEmpty { return code }
        if rawInput == nil, let data = arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: formatted, encoding: .utf8) { return text }
        return source
    }

    var detailText: String {
        var sections: [String] = []
        if let rawInput, !rawInput.isEmpty { sections.append("INPUT\n\(rawInput)") }
        else if !arguments.isEmpty { sections.append("INPUT\n\(arguments)") }
        if let output, !output.isEmpty { sections.append("OUTPUT\n\(output)") }
        return sections.joined(separator: "\n\n")
    }

    var detailInputText: String? {
        let source = rawInput ?? arguments
        guard !source.isEmpty else { return nil }
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return source
        }
        return String(data: formatted, encoding: .utf8) ?? source
    }
}

enum ConversationKind: Hashable {
    case user(text: String, images: [ImageAttachmentRef])
    case images([ImageAttachmentRef], alignEnd: Bool)
    case assistant(text: String, streaming: Bool)
    case assistantActions(text: String, messageId: String?)
    case reasoning(String, running: Bool)
    case tool(ToolCall)
    case commandInput(String)
    case command(name: String, summary: String, body: String?, running: Bool, error: Bool)
    case producedFiles([String])
    case notice(String)
}

struct MessageMetrics: Hashable {
    let runMs: Double?
    let ttftMs: Double?
    let tokensPerSecond: Double?
}

/// WebUI `formatMessageClock`: same day is HH:mm, earlier this year adds
/// M月D日, and another year adds YYYY年M月D日.
func messageClock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)
    let hour = components.hour ?? 0
    let minute = components.minute ?? 0
    let clock = String(format: "%02d:%02d", hour, minute)
    if components.year == nowComponents.year,
       components.month == nowComponents.month,
       components.day == nowComponents.day { return clock }
    let md = "\(components.month ?? 0)月\(components.day ?? 0)日"
    if components.year == nowComponents.year { return "\(md) \(clock)" }
    return "\(components.year ?? 0)年\(md) \(clock)"
}

struct ImageAttachmentRef: Hashable, Identifiable {
    let attachmentId: String
    let mediaType: String
    let bytes: Int
    let width: Int
    let height: Int
    let name: String?
    var id: String { attachmentId }

    init?(json: [String: Any]) {
        guard let attachmentId = json["attachmentId"] as? String,
              let mediaType = json["mediaType"] as? String else { return nil }
        self.attachmentId = attachmentId; self.mediaType = mediaType
        bytes = json.int("bytes"); width = json.int("width"); height = json.int("height")
        name = json["name"] as? String
    }
}

struct MessageImageFit: Equatable {
    enum Crop: Equatable { case center, top, leading }
    let width: CGFloat
    let height: CGFloat
    let crop: Crop

    /// WebUI `singleFit`: clamp the rendered aspect ratio to [0.25, 4], keep
    /// the long edge at 240px, and never enlarge beyond the original pixels.
    static func single(width: Int, height: Int) -> MessageImageFit {
        let safeWidth = max(1, width)
        let safeHeight = max(1, height)
        let natural = CGFloat(safeWidth) / CGFloat(safeHeight)
        let ratio = min(4, max(0.25, natural))
        let box = ratio >= 1
            ? CGSize(width: 240, height: 240 / ratio)
            : CGSize(width: 240 * ratio, height: 240)
        let scale = min(1, CGFloat(safeWidth) / box.width, CGFloat(safeHeight) / box.height)
        let crop: Crop = natural < 0.25 ? .top : natural > 4 ? .leading : .center
        return MessageImageFit(width: max(1, (box.width * scale).rounded()),
                               height: max(1, (box.height * scale).rounded()),
                               crop: crop)
    }
}

struct DraftImage: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let mediaType: String
    let data: Data
    var name: String { url.lastPathComponent }
}

struct DraftImageCandidate {
    let data: Data
    let name: String
    let mediaType: String
}

struct DraftTextFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let mediaType: String
    let data: Data
    var name: String { url.lastPathComponent }
    var byteCountText: String { ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) }

    var promptText: String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let escapedName = name.replacingOccurrences(of: "\"", with: "&quot;")
        return "<attached_file name=\"\(escapedName)\" media_type=\"\(mediaType)\">\n\(text)\n</attached_file>"
    }
}

struct ConversationItem: Hashable, Identifiable {
    let id: String
    let kind: ConversationKind
    let seq: Int?
    let time: Date?
    let stepKey: String?
    let metrics: MessageMetrics?

    init(id: String, kind: ConversationKind, seq: Int?, time: Date?, stepKey: String? = nil,
         metrics: MessageMetrics? = nil) {
        self.id = id; self.kind = kind; self.seq = seq; self.time = time; self.stepKey = stepKey
        self.metrics = metrics
    }
}

/// Presentation-only grouping used by the Codex-style concise transcript.
/// Reasoning remains in the session model but never crosses this boundary;
/// only its running state is retained so the UI can say that work is active.
struct CompactActivityGroup: Hashable, Identifiable {
    let id: String
    let tools: [ToolCall]
    let reasoningRunning: Bool

    var running: Bool { reasoningRunning || tools.contains { $0.state == .running } }

    /// Code is an orchestration container. Concise disclosure skips that
    /// synthetic row and exposes its real dispatched tools with their own
    /// inputs/results, preserving the relationship the Host authored.
    var disclosureTools: [ToolCall] {
        tools.flatMap(Self.disclosureTools(for:))
    }

    var summary: String {
        if let runningCode = tools.last(where: { $0.variant == .code && $0.state == .running }),
           let title = Self.transientTitle(for: runningCode) {
            return title
        }
        if let active = disclosureTools.last(where: { $0.state == .running }) {
            return Self.runningPhrase(for: active)
        }
        if reasoningRunning {
            if let code = tools.last(where: { $0.variant == .code }),
               let title = Self.transientTitle(for: code) { return title }
            return "正在思考"
        }
        let completed = Self.unique(disclosureTools.map(Self.completedPhrase)).joined()
        return completed.isEmpty ? "已完成操作" : completed
    }

    private static func disclosureTools(for tool: ToolCall) -> [ToolCall] {
        guard tool.variant == .code else { return [tool] }
        return tool.subCalls.flatMap(disclosureTools(for:))
    }

    private static func transientTitle(for tool: ToolCall) -> String? {
        let title = tool.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != tool.id else { return nil }
        return title
    }

    private static func unique(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        return phrases.filter { seen.insert($0).inserted }
    }

    private static func completedPhrase(for tool: ToolCall) -> String {
        if tool.name == "todo_write" { return "更新了任务清单" }
        if tool.name == "ask_user_question" { return "请求了输入" }
        if tool.name == "skill" { return "读取了技能" }
        if tool.name.hasPrefix("cordis_") { return "调用了插件" }
        switch tool.variant {
        case .search: return "搜索了内容"
        case .read: return "读取了文件"
        case .bash: return "运行了命令"
        case .write, .edit: return "编辑了文件"
        case .code: return "执行了代码"
        case .others: return "调用了工具"
        }
    }

    private static func runningPhrase(for tool: ToolCall) -> String {
        if tool.name == "todo_write" { return "正在更新任务清单" }
        if tool.name == "ask_user_question" { return "正在等待输入" }
        if tool.name == "skill" { return "正在读取技能" }
        if tool.name.hasPrefix("cordis_") { return "正在调用插件" }
        switch tool.variant {
        case .search: return "正在搜索"
        case .read: return "正在读取文件"
        case .bash: return "正在运行命令"
        case .write, .edit: return "正在编辑文件"
        case .code: return "正在执行代码"
        case .others: return "正在调用工具"
        }
    }
}

enum ConversationDisplayRow: Hashable, Identifiable {
    case message(ConversationItem)
    case activities(CompactActivityGroup)

    var id: String {
        switch self {
        case let .message(item): return item.id
        case let .activities(group): return "compact-activity-\(group.id)"
        }
    }
}

/// Collapses consecutive private-reasoning/tool nodes between visible
/// assistant messages. Completed reasoning-only runs disappear entirely;
/// an active reasoning-only run remains as a generic progress row. Expanding
/// an activity group can therefore expose tools, never reasoning text.
func conciseConversationRows(_ items: [ConversationItem]) -> [ConversationDisplayRow] {
    var result: [ConversationDisplayRow] = []
    var activityItems: [ConversationItem] = []

    func flushActivities() {
        guard let first = activityItems.first else { return }
        let tools = activityItems.compactMap { item -> ToolCall? in
            guard case let .tool(tool) = item.kind else { return nil }
            return tool
        }
        let reasoningRunning = activityItems.contains { item in
            guard case let .reasoning(_, running) = item.kind else { return false }
            return running
        }
        if !tools.isEmpty || reasoningRunning {
            result.append(.activities(CompactActivityGroup(
                id: first.id,
                tools: tools,
                reasoningRunning: reasoningRunning
            )))
        }
        activityItems.removeAll(keepingCapacity: true)
    }

    for item in items {
        switch item.kind {
        case .reasoning, .tool:
            activityItems.append(item)
        default:
            flushActivities()
            result.append(.message(item))
        }
    }
    flushActivities()
    return result
}

struct HistorySnapshot {
    let items: [ConversationItem]
    let hasMore: Bool
    let projections: SessionProjections
    let trajectory: [TrajectoryTurn]
}

enum TrajectoryKind: String, Hashable {
    case system = "SYSTEM"
    case user = "USER"
    case context = "CONTEXT"
    case compacted = "COMPACTED"
    case assistant = "ASSISTANT"
    case tool = "TOOL"
    case subtool = "SUBTOOL"
}

struct TrajectoryUsage: Hashable {
    let input: Int?
    let output: Int?
    let think: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
}

struct TrajectoryCell: Hashable, Identifiable {
    let id: String
    let index: Int
    let kind: TrajectoryKind
    let summary: String
    let detail: String
    let seq: Int
    let startedAt: Date?
    let duration: TimeInterval?
    let usage: TrajectoryUsage?
    let isError: Bool
    let callId: String?
}

struct TrajectoryGroup: Hashable, Identifiable {
    let turn: Int
    let step: Int?
    let cells: [TrajectoryCell]
    var id: String { "\(turn):\(step.map(String.init) ?? "message")" }
    var title: String { step.map { "Step \($0)" } ?? "Message" }
}

struct TrajectoryTurn: Hashable, Identifiable {
    let turn: Int
    let groups: [TrajectoryGroup]
    var id: Int { turn }
}

struct TodoItem: Hashable, Identifiable {
    let content: String
    let status: String
    var id: String { "\(status):\(content)" }
}

struct GoalSnapshot: Hashable, Identifiable {
    let id: String
    let revision: Int
    let objective: String
    let phase: String
    let blockedReason: String?
    let maxGoalRounds: Int
}

struct PlanModeSnapshot: Hashable {
    let active: Bool
    let pending: Bool
    var targetActive: Bool { pending ? !active : active }
}

struct SessionProjections: Hashable {
    var asOfSeq: Int = -1
    var todos: [TodoItem] = []
    var goal: GoalSnapshot?
    var plan: PlanModeSnapshot?
    var permissions: PermissionSelectValue?
    var imageLimits: ImageAttachmentLimits?
    var tokenUsage: TokenUsage?
    var sessionStats: SessionStats?
}

struct ImageAttachmentLimits: Hashable {
    let maxImageBytes: Int
    let maxImagesPerMessage: Int
    let maxMessageImageBytes: Int
    let maxImagePixels: Int
    let mediaTypes: Set<String>

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        let imageBytes = json.int("maxImageBytes")
        let images = json.int("maxImagesPerMessage")
        let messageBytes = json.int("maxMessageImageBytes")
        let pixels = json.int("maxImagePixels")
        guard imageBytes > 0, images > 0, messageBytes > 0, pixels > 0,
              let mediaTypes = json["mediaTypes"] as? [String], !mediaTypes.isEmpty else { return nil }
        maxImageBytes = imageBytes
        maxImagesPerMessage = images
        maxMessageImageBytes = messageBytes
        maxImagePixels = pixels
        self.mediaTypes = Set(mediaTypes)
    }

    var perImageSizeText: String { Self.sizeText(maxImageBytes) }
    var totalSizeText: String { Self.sizeText(maxMessageImageBytes) }

    private static func sizeText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb.rounded() == mb ? "\(Int(mb))MB" : String(format: "%.1fMB", mb)
    }
}

/// Exact Chinese product copy and fallback order from WebUI `image-labels.ts`.
func attachmentErrorText(reason: String, limits: ImageAttachmentLimits?) -> String {
    switch reason {
    case "MODEL_DOES_NOT_SUPPORT_IMAGES":
        return "当前模型不支持图片，请切换支持图片的模型"
    case "SUBAGENT_IMAGE_UNSUPPORTED":
        return "子智能体会话暂不支持图片"
    case "IMAGE_TOO_MANY_PIXELS":
        return "图片分辨率过大，请压缩后重试"
    case "INVALID_IMAGE", "IMAGE_TYPE_MISMATCH":
        return "仅支持 PNG、JPG、WebP、GIF 格式的图片"
    case "TOO_MANY_IMAGES":
        if let limits { return "一条消息最多添加 \(limits.maxImagesPerMessage) 张图片" }
    case "IMAGE_TOO_LARGE":
        if let limits { return "单张图片不能超过 \(limits.perImageSizeText)" }
    case "IMAGES_TOO_LARGE":
        if let limits { return "图片总大小超过 \(limits.totalSizeText)，请移除部分图片" }
    default:
        break
    }
    return "图片发送失败（\(reason)），请重新添加图片后再试"
}

struct PermissionOption: Hashable, Identifiable {
    let value: String
    let name: String
    let description: String?
    var id: String { value }

    var displayName: String {
        if value == "danger-full-access" { return "Full access" }
        let pattern = "^[a-z0-9]+(?:-[a-z0-9]+)*$"
        guard name.range(of: pattern, options: .regularExpression) != nil else { return name }
        return name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct PermissionSelectValue: Hashable {
    let options: [PermissionOption]
    var currentValue: String
}

struct QueuedMessage: Hashable, Identifiable {
    let id: String
    let messageId: String
    let placement: String
    let preview: String
    let text: String?
}

struct CommandDescriptor: Hashable, Identifiable {
    let name: String
    let description: String
    let inputHint: String?
    var id: String { name }
}

struct BackgroundJob: Hashable, Identifiable {
    let id: String
    let kind: String
    let label: String
    let status: String
    let detail: String?
    let startedAt: Date
    let finishedAt: Date?
    var isLive: Bool { status == "running" || status == "stopping" }
}

struct ApprovalRequest: Identifiable, Hashable {
    let rpcId: String
    let sessionId: String
    let approvalId: String
    let toolName: String
    let callId: String?
    let reason: String?
    var id: String { approvalId }
}

struct QuestionOption: Hashable, Identifiable {
    let label: String
    let description: String?
    var id: String { label }
}

struct QuestionIntent: Hashable {
    let kind: String
    let approve: String?
}

struct QuestionItem: Hashable, Identifiable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let options: [QuestionOption]
    let multiSelect: Bool
    let intent: QuestionIntent?
}

struct QuestionRequest: Identifiable, Hashable {
    let rpcId: String
    let sessionId: String
    let questions: [QuestionItem]
    var id: String { rpcId }
}

enum PendingInteraction: Identifiable, Hashable {
    case approval(ApprovalRequest)
    case question(QuestionRequest)

    var id: String {
        switch self { case let .approval(value): return "a:\(value.id)"; case let .question(value): return "q:\(value.id)" }
    }
    var sessionId: String {
        switch self { case let .approval(value): return value.sessionId; case let .question(value): return value.sessionId }
    }
}

enum StreamingAssistantBlock: Hashable {
    case text(String)
    case reasoning(String)
    case toolCall(id: String, name: String, arguments: String)
    case other
}

struct StreamingAssistantAccumulator {
    let turn: Int
    let step: Int
    private(set) var blocks: [Int: StreamingAssistantBlock] = [:]
    private(set) var firstSeq: Int?
    private(set) var firstTime: Date?

    var key: String { "\(turn):\(step)" }

    mutating func resetForRetry() {
        blocks.removeAll(keepingCapacity: true)
        firstSeq = nil
        firstTime = nil
    }

    @discardableResult
    mutating func push(chunk: [String: Any], seq: Int, time: Date?) -> Bool {
        guard let type = chunk["type"] as? String else { return false }
        let index = chunk.int("index")
        switch type {
        case "block-start":
            switch chunk["blockType"] as? String {
            case "text": blocks[index] = .text("")
            case "reasoning": blocks[index] = .reasoning("")
            case "tool-call": blocks[index] = .toolCall(id: "", name: "", arguments: "")
            default: blocks[index] = .other
            }
        case "text-delta":
            let previous = blocks[index]
            let prefix: String = { if case let .text(value) = previous { return value }; return "" }()
            blocks[index] = .text(prefix + (chunk["text"] as? String ?? ""))
        case "reasoning-delta":
            let previous = blocks[index]
            let prefix: String = { if case let .reasoning(value) = previous { return value }; return "" }()
            blocks[index] = .reasoning(prefix + (chunk["text"] as? String ?? ""))
        case "tool-call-delta":
            let previous = blocks[index]
            var id = "", name = "", arguments = ""
            if case let .toolCall(oldId, oldName, oldArguments) = previous {
                id = oldId; name = oldName; arguments = oldArguments
            }
            if id.isEmpty { id = String(describing: chunk["id"] ?? "") }
            if let nextName = chunk["name"] as? String { name = nextName }
            arguments += chunk["argumentsDelta"] as? String ?? ""
            blocks[index] = .toolCall(id: id, name: name, arguments: arguments)
        case "block-end":
            guard let block = chunk.dictionary("block") else { return false }
            switch block["type"] as? String {
            case "text": blocks[index] = .text(block["text"] as? String ?? "")
            case "reasoning": blocks[index] = .reasoning(block["text"] as? String ?? "")
            case "tool-call":
                blocks[index] = .toolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                    arguments: block["arguments"] as? String ?? "")
            default: blocks[index] = .other
            }
        default:
            return false
        }
        if firstSeq == nil, hasVisibleContent {
            firstSeq = seq
            firstTime = time
        }
        return true
    }

    var itemIDs: Set<String> { Set(blocks.keys.map { "assistant-step-\(key)-\($0)" }) }

    func items(running: Bool) -> [ConversationItem] {
        let lastBlockIndex = blocks.keys.max()
        return blocks.keys.sorted().compactMap { index in
            let id = "assistant-step-\(key)-\(index)"
            switch blocks[index] {
            case let .text(text) where !text.isEmpty:
                return ConversationItem(id: id, kind: .assistant(text: text, streaming: running), seq: firstSeq, time: firstTime, stepKey: key)
            case let .reasoning(text) where !text.isEmpty:
                return ConversationItem(id: id, kind: .reasoning(text, running: running && index == lastBlockIndex), seq: firstSeq, time: firstTime, stepKey: key)
            default:
                return nil
            }
        }
    }

    private var hasVisibleContent: Bool {
        blocks.values.contains { block in
            switch block {
            case let .text(text), let .reasoning(text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .other: return true
            case .toolCall: return false
            }
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case server(code: String, message: String, reason: String? = nil)
    case transport(String)

    var serverCode: String? {
        guard case let .server(code, _, _) = self else { return nil }
        return code
    }

    var serverReason: String? {
        guard case let .server(_, _, reason) = self else { return nil }
        return reason
    }

    static func rpcServer(json: [String: Any], fallbackMessage: String = "请求失败") -> APIError {
        let reason = (json["details"] as? [String: Any])?["reason"] as? String
        return .server(code: json["code"] as? String ?? "error",
                       message: json["message"] as? String ?? fallbackMessage,
                       reason: reason)
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器返回了无法识别的数据"
        case let .server(code, message, _): return "\(message)（\(code)）"
        case let .transport(message): return message
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func int(_ key: String) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return 0
    }
    func double(_ key: String) -> Double {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        return 0
    }
}

extension SessionSummary: Identifiable {}
