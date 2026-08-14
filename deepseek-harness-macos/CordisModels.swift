import Foundation

enum CordisCard: Hashable {
    case define(CordisDefineCard)
    case run(CordisRunCard)
    case action(CordisActionCard)
}

struct CordisDefineCard: Hashable {
    let pluginId: String?
    let packageId: String?
    let name: String?
    let purpose: String?
    let hostCode: String?
    let clientCode: String?
    let output: String?
    let errorSummary: String?
    let state: ToolState
}

struct CordisRunCard: Hashable {
    let pluginId: String?
    let packageId: String?
    let pluginRunId: String?
    let mode: String?
    let seq: Int?
    let output: String?
    let errorSummary: String?
    let state: ToolState
}

struct CordisActionCard: Hashable {
    let pluginId: String?
    let output: String?
    let errorSummary: String?
    let state: ToolState
}

/// Native equivalent of ui-cordis/card-model.ts. It intentionally derives
/// replay cards only from the frozen call/result slice, never from guessed
/// identifiers embedded in human-readable output.
enum CordisCardModel {
    static func make(name toolName: String, callId: String, argsRaw: String, output: String?,
                     resultMeta: [String: Any]?, resultSeq: Int?, state: ToolState) -> CordisCard? {
        guard toolName.hasPrefix("cordis_") else { return nil }
        let args = parseObject(argsRaw)
        let safeMeta = state == .ok ? resultMeta : nil
        switch toolName {
        case "cordis_define":
            let code = args?["code"] as? [String: Any]
            let rawName = argsRaw.isEmpty ? nil : firstLine(argsRaw)
            return .define(CordisDefineCard(
                pluginId: string(safeMeta, "pluginId"), packageId: string(safeMeta, "packageId"),
                name: string(args, "name") ?? rawName, purpose: string(args, "purpose"),
                hostCode: string(code, "host"), clientCode: string(code, "client"), output: output,
                errorSummary: state == .error ? output.map(firstLine) : nil, state: state))
        case "cordis_run":
            let rawMode = string(args, "mode")
            let mode = rawMode == "run" || rawMode == "update" ? rawMode : nil
            return .run(CordisRunCard(
                pluginId: string(safeMeta, "pluginId") ?? string(args, "pluginId"),
                packageId: string(safeMeta, "packageId") ?? string(args, "packageId"),
                pluginRunId: string(safeMeta, "pluginRunId"), mode: mode,
                seq: state == .running ? nil : resultSeq, output: output,
                errorSummary: state == .error ? output.map(firstLine) : nil, state: state))
        case "cordis_stop", "cordis_undefine":
            return .action(CordisActionCard(
                pluginId: string(args, "pluginId") ?? string(args, "id"), output: output,
                errorSummary: state == .error ? output.map(firstLine) : nil, state: state))
        default:
            return nil
        }
    }

    private static func parseObject(_ source: String) -> [String: Any]? {
        guard let data = source.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func string(_ source: [String: Any]?, _ key: String) -> String? {
        guard let value = source?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func firstLine(_ source: String) -> String {
        source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? source
    }
}
