import Foundation

/// Platform-neutral rules shared by the macOS and iOS transcript renderers.
/// The durable log contains plugin snapshots and system reminders that use the
/// `user` role; only an explicit `source.kind == user` is visible chat input.
enum HarnessTranscriptParsing {
    struct ToolResult {
        let id: String
        let output: String
        let isError: Bool
        let stopped: Bool
        let errorCode: String?
    }
    static func event(from wrapper: [String: Any]) -> [String: Any] {
        wrapper["event"] as? [String: Any] ?? wrapper
    }

    static func data(from event: [String: Any]) -> [String: Any] {
        event["data"] as? [String: Any] ?? [:]
    }

    static func message(from data: [String: Any]) -> [String: Any] {
        data["message"] as? [String: Any] ?? [:]
    }

    static func content(data: [String: Any], message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]]
            ?? data["content"] as? [[String: Any]]
            ?? []
    }

    static func isVisibleUserMessage(data: [String: Any], message: [String: Any]) -> Bool {
        let source = data["source"] as? [String: Any]
            ?? message["source"] as? [String: Any]
        return source?["kind"] as? String == "user"
    }

    static func text(from content: [[String: Any]], separator: String = "\n") -> String {
        content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: separator)
    }

    /// Tool results may be flat protocol events or wrapped tool-role messages.
    /// This is the same normalization used by the macOS history projection.
    static func toolResult(from data: [String: Any]) -> ToolResult? {
        let message = data["message"] as? [String: Any]
        let source = message?["source"] as? [String: Any]
        var id = data["callId"] as? String ?? source?["callId"] as? String ?? ""
        var parts: [String] = []
        var isError = data["isError"] as? Bool ?? false
        for wrapper in message?["content"] as? [[String: Any]] ?? [] {
            if let value = wrapper["toolCallId"] as? String { id = value }
            isError = isError || (wrapper["isError"] as? Bool ?? false)
            for block in wrapper["content"] as? [[String: Any]] ?? [] {
                if block["type"] as? String == "text", let text = block["text"] as? String {
                    parts.append(text)
                } else if JSONSerialization.isValidJSONObject(block),
                          let encoded = try? JSONSerialization.data(withJSONObject: block, options: [.prettyPrinted]),
                          let text = String(data: encoded, encoding: .utf8) {
                    parts.append(text)
                }
            }
        }
        if parts.isEmpty {
            parts.append(text(from: data["content"] as? [[String: Any]] ?? []))
        }
        let error = data["error"] as? [String: Any]
        let errorCode = error?["code"] as? String
        if parts.allSatisfy(\.isEmpty), let errorCode {
            parts.append("\(error?["name"] as? String ?? "Error"): \(errorCode)")
        }
        return ToolResult(id: id,
                          output: parts.filter { !$0.isEmpty }.joined(separator: "\n"),
                          isError: isError,
                          stopped: errorCode == "interrupted" || errorCode == "ASK_ABORTED",
                          errorCode: errorCode)
    }
}
