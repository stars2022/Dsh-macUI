import Foundation

/// Platform-neutral block tree used by both native clients. Inline syntax is
/// still delegated to AttributedString's CommonMark implementation.
enum HarnessMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [HarnessMarkdownListItem])
    case quote([HarnessMarkdownBlock])
    case thematicBreak
    case code(language: String?, source: String)
    case table(header: [String], rows: [[String]])
}

struct HarnessMarkdownListItem: Equatable {
    let depth: Int
    let text: String
    let checked: Bool?
    let ordered: Bool?
    let number: Int?
}

/// Deterministic CommonMark block projection shared by macOS and iOS. Keeping
/// this below the view layer prevents the two clients from drifting on lists,
/// fences, quotes, headings and tables.
enum HarnessMarkdownParser {
    static func parse(_ source: String) -> [HarnessMarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [HarnessMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }

            if let fence = fenceStart(line) {
                index += 1
                var body: [String] = []
                while index < lines.count, !isFenceEnd(lines[index], marker: fence.marker) {
                    body.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: fence.language, source: body.joined(separator: "\n")))
                continue
            }
            if let value = heading(line) {
                blocks.append(.heading(level: value.level, text: value.text)); index += 1; continue
            }
            if index + 1 < lines.count, let level = setextLevel(lines[index + 1]) {
                blocks.append(.heading(level: level, text: line.trimmingCharacters(in: .whitespaces)))
                index += 2; continue
            }
            if thematicBreak(line) { blocks.append(.thematicBreak); index += 1; continue }
            if quoteLine(line) != nil {
                var quoted: [String] = []
                while index < lines.count, let value = quoteLine(lines[index]) {
                    quoted.append(value); index += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }
            if let first = listLine(line) {
                var items: [HarnessMarkdownListItem] = []
                let ordered = first.ordered
                let start = first.number ?? 1
                let baseDepth = first.depth
                while index < lines.count {
                    if let item = listLine(lines[index]),
                       item.depth > baseDepth || (item.depth == baseDepth && item.ordered == ordered) {
                        items.append(.init(depth: item.depth - baseDepth, text: item.text, checked: item.checked,
                                           ordered: item.ordered, number: item.number))
                        index += 1; continue
                    }
                    let indentation = lines[index].prefix(while: { $0 == " " }).count
                    if !items.isEmpty, indentation > baseDepth * 2,
                       !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let previous = items.removeLast()
                        items.append(.init(depth: previous.depth,
                                           text: previous.text + "\n" + lines[index].trimmingCharacters(in: .whitespaces),
                                           checked: previous.checked, ordered: previous.ordered, number: previous.number))
                        index += 1; continue
                    }
                    break
                }
                blocks.append(.list(ordered: ordered, start: start, items: items))
                continue
            }
            if index + 1 < lines.count,
               let header = tableCells(line), tableDivider(lines[index + 1], count: header.count) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableCells(lines[index]), !row.isEmpty {
                    rows.append(padded(row, to: header.count)); index += 1
                }
                blocks.append(.table(header: header, rows: rows)); continue
            }

            var paragraph = [line]
            index += 1
            while index < lines.count, !startsBlock(lines, at: index) {
                paragraph.append(lines[index]); index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty || fenceStart(line) != nil || heading(line) != nil ||
            thematicBreak(line) || quoteLine(line) != nil || listLine(line) != nil { return true }
        if index + 1 < lines.count, setextLevel(lines[index + 1]) != nil { return true }
        if index + 1 < lines.count, let cells = tableCells(line), tableDivider(lines[index + 1], count: cells.count) { return true }
        return false
    }

    private static func fenceStart(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker: String
        if trimmed.hasPrefix("```") { marker = "```" }
        else if trimmed.hasPrefix("~~~") { marker = "~~~" }
        else { return nil }
        let info = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (marker, info.isEmpty ? nil : info.split(whereSeparator: \.isWhitespace).first.map(String.init))
    }

    private static func isFenceEnd(_ line: String, marker: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), trimmed.dropFirst(count).first == " " else { return nil }
        var text = String(trimmed.dropFirst(count + 1)).trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        return (count, text)
    }

    private static func thematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        let compact = line.filter { !$0.isWhitespace }
        guard !compact.isEmpty, let first = compact.first, first == "=" || first == "-",
              compact.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    private static func quoteLine(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == ">" else { return nil }
        var body = trimmed.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    private static func listLine(_ line: String) -> (ordered: Bool, number: Int?, depth: Int, text: String, checked: Bool?)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        let body = String(line.dropFirst(spaces))
        let pattern = #"^(?:([-+*])|([0-9]+)[.)])\s+(.+)$"#
        guard let match = body.firstMatch(of: try! Regex(pattern)) else { return nil }
        let marker = String(body[match.range])
        guard let markerEnd = marker.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let token = String(marker[..<markerEnd])
        var text = String(marker[markerEnd...]).trimmingCharacters(in: .whitespaces)
        let ordered = token.first?.isNumber == true
        let number = ordered ? Int(token.dropLast()) : nil
        var checked: Bool?
        if text.hasPrefix("[ ] ") { checked = false; text.removeFirst(4) }
        else if text.lowercased().hasPrefix("[x] ") { checked = true; text.removeFirst(4) }
        return (ordered, number, spaces / 2, text, checked)
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        let cells = value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count > 1 ? cells : nil
    }

    private static func tableDivider(_ line: String, count: Int) -> Bool {
        guard let cells = tableCells(line), cells.count == count else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }

    private static func padded(_ row: [String], to count: Int) -> [String] {
        Array((row + Array(repeating: "", count: max(0, count - row.count))).prefix(count))
    }
}
