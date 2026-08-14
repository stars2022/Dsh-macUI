import AppKit
import Foundation
import SwiftUI

/// Block model used by the native renderer.  It deliberately mirrors the
/// WebUI's mdast-level layout instead of flattening a whole answer into one
/// `Text`, so paragraphs, fences and tables keep their own chrome.
enum NativeMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [NativeMarkdownListItem])
    case quote([NativeMarkdownBlock])
    case thematicBreak
    case code(language: String?, source: String)
    case table(header: [String], rows: [[String]])
}

struct NativeMarkdownListItem: Equatable {
    let depth: Int
    let text: String
    let checked: Bool?
    let ordered: Bool?
    let number: Int?

    init(depth: Int, text: String, checked: Bool?, ordered: Bool? = nil, number: Int? = nil) {
        self.depth = depth
        self.text = text
        self.checked = checked
        self.ordered = ordered
        self.number = number
    }
}

/// A small, deterministic CommonMark block parser. Inline syntax remains the
/// system Markdown parser; this layer owns precisely the structures whose CSS
/// layout cannot be represented by one attributed string.
enum NativeMarkdownParser {
    static func parse(_ source: String) -> [NativeMarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [NativeMarkdownBlock] = []
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

            if let heading = heading(line) {
                blocks.append(.heading(level: heading.level, text: heading.text)); index += 1; continue
            }

            if index + 1 < lines.count, let level = setextLevel(lines[index + 1]) {
                blocks.append(.heading(level: level, text: line.trimmingCharacters(in: .whitespaces)))
                index += 2
                continue
            }

            if thematicBreak(line) {
                blocks.append(.thematicBreak); index += 1; continue
            }

            if quoteLine(line) != nil {
                var quoted: [String] = []
                while index < lines.count, let value = quoteLine(lines[index]) {
                    quoted.append(value); index += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            if let first = listLine(line) {
                var items: [NativeMarkdownListItem] = []
                let ordered = first.ordered
                let start = first.number ?? 1
                let baseDepth = first.depth
                while index < lines.count {
                    if let item = listLine(lines[index]),
                       item.depth > baseDepth || (item.depth == baseDepth && item.ordered == ordered) {
                        items.append(.init(depth: item.depth - baseDepth, text: item.text, checked: item.checked,
                                           ordered: item.ordered, number: item.number))
                        index += 1
                        continue
                    }
                    let indentation = lines[index].prefix(while: { $0 == " " }).count
                    if !items.isEmpty, indentation > baseDepth * 2,
                       !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let previous = items.removeLast()
                        items.append(.init(depth: previous.depth,
                                           text: previous.text + "\n" + lines[index].trimmingCharacters(in: .whitespaces),
                                           checked: previous.checked, ordered: previous.ordered, number: previous.number))
                        index += 1
                        continue
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

struct NativeMarkdownView: View {
    let source: String
    var streaming = false
    private var blocks: [NativeMarkdownBlock] { NativeMarkdownParser.parse(source) }

    var body: some View {
        let parsed = blocks
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { index, block in
                NativeMarkdownBlockView(block: block, streaming: streaming)
                    .padding(.top, index == 0 ? 0 : gap(after: parsed[index - 1], before: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Color(nsColor: Theme.business))
        .textSelection(.enabled)
    }

    private func gap(after previous: NativeMarkdownBlock, before next: NativeMarkdownBlock) -> CGFloat {
        max(bottomMargin(previous), topMargin(next))
    }

    private func topMargin(_ block: NativeMarkdownBlock) -> CGFloat {
        if case let .heading(level, _) = block { return level <= 3 ? 32 : 16 }
        if case .thematicBreak = block { return 32 }
        return 16
    }

    private func bottomMargin(_ block: NativeMarkdownBlock) -> CGFloat {
        if case .thematicBreak = block { return 32 }
        return 16
    }
}

private struct NativeMarkdownBlockView: View {
    let block: NativeMarkdownBlock
    var streaming = false

    @ViewBuilder var body: some View {
        switch block {
        case let .paragraph(text):
            inline(text, size: 16, weight: .regular).lineSpacing(6)
        case let .heading(level, text):
            inline(text, size: headingSize(level), weight: level <= 3 ? .bold : .semibold)
                .lineSpacing(headingSpacing(level))
        case let .list(ordered, start, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            } else {
                                Text(marker(for: item, index: index, defaultOrdered: ordered, start: start))
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .trailing)
                        inline(item.text, size: 16, weight: .regular).lineSpacing(6)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case let .quote(children):
            HStack(alignment: .top, spacing: 14) {
                Rectangle().fill(Color.secondary.opacity(0.55)).frame(width: 2)
                NativeMarkdownNestedBlocks(blocks: children, streaming: streaming)
            }
        case .thematicBreak:
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        case let .code(language, source):
            // WebUI intentionally withholds fence grammar highlighting while
            // the message streams; the finalized message self-heals to the
            // declared language without changing the code-block geometry.
            NativeMarkdownCodeBlock(language: streaming ? nil : language, source: source)
        case let .table(header, rows):
            NativeMarkdownTable(header: header, rows: rows)
        }
    }

    private func inline(_ text: String, size: CGFloat, weight: Font.Weight) -> Text {
        var parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in parsed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                parsed[run.range].font = .system(size: 14, design: .monospaced)
                parsed[run.range].backgroundColor = Color(nsColor: Theme.markdownInlineCode)
            }
        }
        return Text(parsed).font(.system(size: size, weight: weight))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 24; case 2: return 22; case 3: return 20; default: return 16 }
    }

    private func headingSpacing(_ level: Int) -> CGFloat {
        switch level { case 1: return 4; case 2: return 4; case 3: return 4; default: return 6 }
    }

    private func marker(for item: NativeMarkdownListItem, index: Int, defaultOrdered: Bool, start: Int) -> String {
        let isOrdered = item.ordered ?? defaultOrdered
        if !isOrdered { return "•" }
        return "\(item.number ?? (start + index))."
    }
}

private struct NativeMarkdownNestedBlocks: View {
    let blocks: [NativeMarkdownBlock]
    var streaming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in NativeMarkdownBlockView(block: block, streaming: streaming) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeMarkdownCodeBlock: View {
    let language: String?
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(language ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: copy) {
                    DeepSeekIcon(kind: copied ? .check : .copy, size: 14)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(copied ? "已复制" : "复制")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(nsColor: Theme.markdownCodeBanner))

            Text(NativeSyntaxHighlighter.attributed(source, language: language, fontSize: 13))
                .font(.system(size: 13, design: .monospaced)).lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: Theme.markdownCode))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func copy() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}

private struct NativeMarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in row(cells, header: false) }
            }
        }
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                let parsed = (try? AttributedString(markdown: cell, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cell)
                Text(parsed)
                    .font(.system(size: header ? 14 : 14, weight: header ? .semibold : .regular))
                    .lineSpacing(4)
                    .frame(minWidth: 100, maxWidth: 320, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.leading, index == 0 ? 0 : 16)
                    .padding(.trailing, index == cells.count - 1 ? 0 : 16)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(header ? 0.12 : 0.08)).frame(height: 1) }
    }
}
