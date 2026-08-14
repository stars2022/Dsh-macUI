import SwiftUI

private let toolCodeFont = Font.system(size: 12, design: .monospaced)

private struct ToolCardSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(Color(nsColor: Theme.markdownCode))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ToolPresentationView: View {
    @EnvironmentObject private var model: AppModel
    let presentation: ToolPresentation
    var detailMode = false

    var body: some View {
        switch presentation {
        case let .terminal(card): TerminalToolCardView(card: card, maxLines: detailMode ? 16 : nil, detailMode: detailMode).padding(.bottom, chatBottomMargin)
        case let .read(card): ReadToolCardView(card: card, maxLines: detailMode ? 16 : 8).padding(.bottom, chatBottomMargin)
        case let .search(card): SearchToolCardView(card: card, maxLines: detailMode ? 16 : 8, chatMode: !detailMode)
        case let .diff(card): DiffToolCardView(card: card, maxLines: detailMode ? 16 : 8).padding(.bottom, chatBottomMargin)
        case let .web(card): WebToolCardView(card: card).padding(.bottom, chatBottomMargin)
        }
    }

    private var chatBottomMargin: CGFloat { detailMode ? 0 : 4 }
}

private struct TerminalToolCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: TerminalToolCard
    let maxLines: Int?
    let detailMode: Bool
    private let terminalOutput: TerminalANSIOutput
    @State private var expanded = false
    @State private var copied = false

    init(card: TerminalToolCard, maxLines: Int?, detailMode: Bool) {
        self.card = card
        self.maxLines = maxLines
        self.detailMode = detailMode
        self.terminalOutput = TerminalANSIParser.parse(card.output ?? "")
    }

    var body: some View {
        ToolCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    LifecycleStateDot(state: terminalState)
                        .padding(.leading, 8)
                        .frame(width: 30, height: terminalLineHeight, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(commandLines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if index == 0, let cwd = resolvedCwd, !cwd.isEmpty {
                                    Text(URL(fileURLWithPath: cwd).lastPathComponent).foregroundStyle(.tertiary)
                                } else { Text("$").foregroundStyle(.tertiary) }
                                Text(line).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                            }.frame(minHeight: terminalLineHeight, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let statusText { Text(statusText).foregroundStyle(Color(nsColor: Theme.stateError)).padding(.leading, 12) }
                    if !card.running, !terminalOutput.isEmpty {
                        let output = card.output ?? ""
                        Button(copied ? "复制成功" : "复制") { copy(output) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 12)
                    }
                }
                .font(toolCodeFont).padding(.vertical, 9).padding(.trailing, 14)
                if !card.running {
                    Divider().opacity(0.55)
                    ScrollView([.horizontal, .vertical]) {
                        if terminalOutput.isEmpty {
                            Text("无输出").foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(headLines.enumerated()), id: \.offset) { _, line in outputLine(line) }
                                if hiddenCount > 0 {
                                    Button(expanded ? "收起" : "… 其余 \(hiddenCount) 行") { expanded.toggle() }
                                        .buttonStyle(.plain).foregroundStyle(.tertiary).frame(height: 22)
                                }
                                if !expanded {
                                    ForEach(Array(tailLines.enumerated()), id: \.offset) { _, line in outputLine(line) }
                                }
                            }
                        }
                    }
                    .font(toolCodeFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12).padding(.leading, 30).padding(.trailing, 14)
                    .frame(maxHeight: detailMode ? nil : 224)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var commandLines: [String] {
        let body = card.command.hasSuffix("\n") ? String(card.command.dropLast()) : card.command
        return body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    private var outputLines: [TerminalANSILine] { terminalOutput.lines }
    private var hiddenCount: Int {
        guard let maxLines, !expanded else { return 0 }
        return max(0, outputLines.count - maxLines)
    }
    private var headLines: [TerminalANSILine] {
        guard let maxLines, !expanded, outputLines.count > maxLines else { return outputLines }
        return Array(outputLines.prefix((maxLines + 1) / 2))
    }
    private var tailLines: [TerminalANSILine] {
        guard let maxLines, !expanded, outputLines.count > maxLines else { return [] }
        return Array(outputLines.suffix(maxLines - (maxLines + 1) / 2))
    }
    private func outputLine(_ line: TerminalANSILine) -> some View {
        Text(line.attributedString)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: terminalLineHeight, alignment: .leading)
    }
    private var terminalLineHeight: CGFloat { detailMode ? 22 : 18 }
    private var resolvedCwd: String? {
        let session = model.current?.cwd
        if card.usesSessionCwd { return session }
        guard let cwd = card.cwd, !cwd.isEmpty else { return nil }
        if cwd.hasPrefix("/") { return URL(fileURLWithPath: cwd).standardized.path }
        guard let session else { return URL(fileURLWithPath: cwd).standardized.path }
        return URL(fileURLWithPath: session).appendingPathComponent(cwd).standardized.path
    }
    private var statusText: String? {
        if let signal = card.signal { return "信号 \(signal)" }
        if let exit = card.exitCode, exit != 0 { return "退出码 \(exit)" }
        return nil
    }
    private var terminalState: LifecycleStateDot.State {
        if card.running { return .ongoing }
        return statusText == nil ? .done : .error
    }
    private func copy(_ output: String) {
        guard !copied else { return }
        model.copy(output); copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}

/// Native counterpart of WebUI `StateDot`: a 10px halo/core for settled
/// states and the eight-cell, one-second pixel chase for an ongoing command.
struct LifecycleStateDot: View {
    enum State { case done, warning, ongoing, error }
    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if state == .ongoing {
            TimelineView(.animation(minimumInterval: 0.125, paused: reduceMotion)) { timeline in
                Canvas { context, _ in
                    let tick = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.125) % 8
                    let cells: [CGPoint] = [.init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 8, y: 0), .init(x: 8, y: 4),
                                              .init(x: 8, y: 8), .init(x: 4, y: 8), .init(x: 0, y: 8), .init(x: 0, y: 4)]
                    for (index, point) in cells.enumerated() {
                        let age = (tick - index + 8) % 8
                        let opacity: Double = age == 0 ? 1 : age == 1 ? 0.6 : age == 2 ? 0.35 : 0.15
                        context.opacity = opacity
                        context.fill(Path(CGRect(origin: point, size: CGSize(width: 2, height: 2))),
                                     with: .color(Color(nsColor: Theme.stateOngoing)))
                    }
                }
            }.frame(width: 10, height: 10)
        } else {
            ZStack {
                Circle().fill(color.opacity(0.10))
                Circle().fill(color).frame(width: 6, height: 6)
            }.frame(width: 10, height: 10)
        }
    }

    private var color: Color {
        switch state {
        case .done: return Color(nsColor: Theme.stateSuccess)
        case .warning: return Color(nsColor: Theme.stateWarning)
        case .error: return Color(nsColor: Theme.stateError)
        case .ongoing: return Color(nsColor: Theme.stateOngoing)
        }
    }
}

private struct ReadToolCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: ReadToolCard
    let maxLines: Int
    @State private var expanded = false
    @State private var copied = false

    private var highlightedLines: [Int: AttributedString] {
        let source = card.lines.map(\.text).joined(separator: "\n")
        guard let highlighted = NativeSyntaxHighlighter.attributedLines(source, language: card.language),
              highlighted.count == card.lines.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(card.lines.map(\.number), highlighted))
    }

    var body: some View {
        ToolCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(displayLabel).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 0)
                    if card.lines.count < card.totalLines { Text("显示 \(card.lines.count) / \(card.totalLines) 行") }
                    if let language = card.language { Text(language) }
                    if !card.lines.isEmpty { Button(copied ? "复制成功" : "复制") { copy() }.buttonStyle(.plain) }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(minHeight: 20)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(nsColor: Theme.markdownCodeBanner))
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleHead) { line in lineRow(line) }
                        if hiddenCount > 0 {
                            Button(expanded ? "收起" : "… 其余 \(hiddenCount) 行") { expanded.toggle() }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).frame(height: 22).padding(.leading, 48)
                        }
                        if !expanded { ForEach(visibleTail) { line in lineRow(line) } }
                    }.padding(.vertical, 12)
                }
            }
        }
    }

    private var hiddenCount: Int { max(0, card.lines.count - maxLines) }
    private var displayLabel: String {
        if let label = card.label { return label }
        guard let cwd = model.current?.cwd else { return card.path }
        let root = URL(fileURLWithPath: cwd).standardized.path
        let path = URL(fileURLWithPath: card.path).standardized.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : card.path
    }
    private var visibleHead: [ReadToolLine] { expanded || hiddenCount == 0 ? card.lines : Array(card.lines.prefix((maxLines + 1) / 2)) }
    private var visibleTail: [ReadToolLine] { hiddenCount == 0 ? [] : Array(card.lines.suffix(maxLines - (maxLines + 1) / 2)) }
    private func lineRow(_ line: ReadToolLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(line.number)").foregroundStyle(.tertiary).frame(width: 48, alignment: .trailing).padding(.trailing, 14)
            Text(highlightedLines[line.number] ?? AttributedString(line.text))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }.font(toolCodeFont).frame(minHeight: 22)
    }
    private func copy() {
        guard !copied else { return }
        model.copy(card.lines.map(\.text).joined(separator: "\n")); copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}

private struct SearchToolCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: SearchToolCard
    let maxLines: Int
    let chatMode: Bool
    @State private var collapsedFiles: Set<Int> = []
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolCardSurface {
                VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(summary).foregroundStyle(.secondary)
                    Spacer()
                    if !rows.isEmpty { Button(copied ? "复制成功" : "复制") { copy() }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .font(.system(size: 13))
                .frame(minHeight: 20)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(nsColor: Theme.markdownCodeBanner))
                if rows.isEmpty {
                    Text("无结果").font(toolCodeFont).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 12)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(headRows.enumerated()), id: \.offset) { _, row in searchRow(row) }
                            if hiddenCount > 0 {
                                Button(expanded ? "收起" : "… 其余 \(hiddenCount) 行") { expanded.toggle() }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).frame(height: 22).padding(.horizontal, 14)
                            }
                            if let tailHeader { searchRow(tailHeader) }
                            if !expanded { ForEach(Array(tailRows.enumerated()), id: \.offset) { _, row in searchRow(row) } }
                        }
                        .font(toolCodeFont).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8).padding(.bottom, 12)
                    }.frame(maxHeight: 196)
                }
            }
            }
            .padding(.bottom, hasRecovery && chatMode ? 4 : 0)
            if card.truncated, let recovery = card.recovery, !recovery.isEmpty {
                Text(recovery)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 4).padding(.bottom, 4)
            }
        }
        .padding(.bottom, chatMode && !hasRecovery ? 4 : 0)
    }

    private var shown: Int {
        switch card.content { case let .paths(paths): return paths.count; case let .matches(files): return files.reduce(0) { $0 + $1.matches.count } }
    }
    private var hasRecovery: Bool { card.truncated && card.recovery?.isEmpty == false }
    private var summary: String {
        let count = card.truncated ? "显示 \(shown) / 共 \(card.total)" : "\(shown)"
        switch card.content { case .paths: return "\(count) 个路径"; case let .matches(files): return "\(count) 处匹配 · \(files.count) 个文件" }
    }
    private var copyText: String {
        switch card.content {
        case let .paths(paths): return paths.joined(separator: "\n")
        case let .matches(files): return files.map { file in ([file.path] + file.matches.map { "\($0.lineNumber): \($0.line)" }).joined(separator: "\n") }.joined(separator: "\n\n")
        }
    }
    private enum Row {
        case path(String)
        case file(index: Int, path: String, count: Int)
        case match(fileIndex: Int, number: Int, line: String)
    }
    private var rows: [Row] {
        switch card.content {
        case let .paths(paths): return paths.map(Row.path)
        case let .matches(files):
            var result: [Row] = []
            for (index, file) in files.enumerated() {
                result.append(.file(index: index, path: file.path, count: file.matches.count))
                if !collapsedFiles.contains(index) {
                    result.append(contentsOf: file.matches.map { .match(fileIndex: index, number: $0.lineNumber, line: $0.line) })
                }
            }
            return result
        }
    }
    private var hiddenCount: Int { max(0, rows.count - maxLines) }
    private var slices: HeadTailSlices<Row> {
        HeadTail.slices(rows, maxLines: maxLines, expanded: expanded, owner: { row in
            if case let .match(fileIndex, _, _) = row { return fileIndex }
            return nil
        }, isHeader: { row, fileIndex in
            if case let .file(index, _, _) = row { return index == fileIndex }
            return false
        })
    }
    private var headRows: [Row] { slices.head }
    private var tailHeader: Row? { slices.tailHeader }
    private var tailRows: [Row] { slices.tail }
    @ViewBuilder private func searchRow(_ row: Row) -> some View {
        switch row {
        case let .path(path): Text(path).fixedSize(horizontal: true, vertical: false).frame(minHeight: 22).padding(.horizontal, 14)
        case let .file(index, path, count):
            Button { toggle(index) } label: {
                HStack(spacing: 8) { Text(path).fontWeight(.semibold).fixedSize(horizontal: true, vertical: false); Text("\(count)").foregroundStyle(.tertiary) }.frame(minHeight: 22)
            }.buttonStyle(.plain).padding(.horizontal, 14)
        case let .match(_, number, line):
            HStack(spacing: 0) { Text("\(number): ").foregroundStyle(.tertiary); Text(line) }
                .fixedSize(horizontal: true, vertical: false).frame(minHeight: 22).padding(.horizontal, 14)
        }
    }
    private func toggle(_ index: Int) { if collapsedFiles.contains(index) { collapsedFiles.remove(index) } else { collapsedFiles.insert(index) } }
    private func copy() {
        guard !copied else { return }
        model.copy(copyText); copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}

private struct DiffRow: Identifiable {
    enum Kind { case path, gap, deleted, added }
    let id: Int
    let kind: Kind
    let text: String
}

private struct DiffToolCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: DiffToolCard
    let maxLines: Int
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        ToolCardSurface {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(headRows) { rowView($0) }
                            if hiddenCount > 0 {
                                Button(expanded ? "收起" : "… 其余 \(hiddenCount) 行") { expanded.toggle() }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary).frame(height: 22)
                            }
                            if !expanded { ForEach(tailRows) { rowView($0) } }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(copied ? "复制成功" : "复制") { copy() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 13)).padding(.top, 8).padding(.trailing, 12)
                }
                Text("└ +\(card.additions) -\(card.deletions) · \(card.fileCount) file\(card.fileCount == 1 ? "" : "s")")
                    .font(toolCodeFont).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    private var rows: [DiffRow] {
        var result: [DiffRow] = []; var previous: String?; var index = 0
        func append(_ kind: DiffRow.Kind, _ text: String) { result.append(DiffRow(id: index, kind: kind, text: text)); index += 1 }
        for diff in card.diffs {
            append(diff.path == previous ? .gap : .path, diff.path == previous ? "⋯" : diff.path); previous = diff.path
            if let old = diff.oldText { contentLines(old).forEach { append(.deleted, $0) } }
            contentLines(diff.newText).forEach { append(.added, $0) }
        }
        return result
    }
    private var hiddenCount: Int { max(0, rows.count - maxLines) }
    private var headRows: [DiffRow] { expanded || hiddenCount == 0 ? rows : Array(rows.prefix((maxLines + 1) / 2)) }
    private var tailRows: [DiffRow] { hiddenCount == 0 ? [] : Array(rows.suffix(maxLines - (maxLines + 1) / 2)) }
    private var copyText: String { rows.map { row in row.kind == .added ? "+ \(row.text)" : row.kind == .deleted ? "- \(row.text)" : row.text }.joined(separator: "\n") }
    private func contentLines(_ text: String) -> [String] { text.isEmpty ? [] : String(text.dropLast(text.hasSuffix("\n") ? 1 : 0)).split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    private func rowView(_ row: DiffRow) -> some View {
        HStack(spacing: 0) {
            Text(prefix(row))
                .frame(width: row.kind == .added || row.kind == .deleted ? 22 : 0, alignment: .center)
            Text(row.text).fontWeight(row.kind == .path ? .semibold : .regular)
                .padding(.trailing, row.kind == .path ? 56 : 14)
        }
        .font(toolCodeFont)
        .foregroundStyle(color(row))
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 22)
        .background(rowBackground(row))
        .textSelection(.enabled)
    }
    private func prefix(_ row: DiffRow) -> String { row.kind == .added ? "+ " : row.kind == .deleted ? "- " : "" }
    private func color(_ row: DiffRow) -> Color {
        row.kind == .added ? Color(nsColor: Theme.stateSuccess)
            : row.kind == .deleted ? Color(nsColor: Theme.stateError)
            : row.kind == .gap ? Color.secondary : Color.primary
    }
    private func rowBackground(_ row: DiffRow) -> Color {
        if row.kind == .added { return Color(nsColor: Theme.stateSuccess).opacity(0.10) }
        if row.kind == .deleted { return Color(nsColor: Theme.stateError).opacity(0.10) }
        return .clear
    }
    private func copy() {
        guard !copied else { return }
        model.copy(copyText); copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
    }
}

private struct WebToolCardView: View {
    let card: WebToolCard

    var body: some View {
        ToolCardSurface {
            switch card {
            case let .fetch(url, status, truncated):
                VStack(alignment: .leading, spacing: 6) {
                    safeLink(url, label: url).font(.system(size: 13, design: .monospaced))
                    HStack(spacing: 12) { Text("HTTP \(status)"); if truncated { Text("内容已截断").foregroundStyle(.tertiary) } }
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            case let .search(answer, sources, truncated):
                VStack(alignment: .leading, spacing: 8) {
                    if let answer, !answer.isEmpty { NativeMarkdownView(source: answer) }
                    if (answer == nil || answer?.isEmpty == true) && sources.isEmpty { Text("未找到结果").foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                                HStack(alignment: .top, spacing: 7) {
                                    Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 2) {
                                        safeLink(source.url, label: source.title?.isEmpty == false ? source.title! : host(source.url)).font(.system(size: 14))
                                        if let snippet = source.snippet, !snippet.isEmpty { Text(snippet).font(.system(size: 13)).foregroundStyle(.secondary) }
                                        if let date = source.publishedAt, !date.isEmpty { Text(date).font(.system(size: 13)).foregroundStyle(.tertiary) }
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 320)
                    if truncated { Text("来源列表已截断").font(.system(size: 13)).foregroundStyle(.tertiary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func safeLink(_ raw: String, label: String) -> some View {
        if let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" { Link(label, destination: url) }
        else { Text(label) }
    }
    private func host(_ raw: String) -> String { URL(string: raw)?.host?.isEmpty == false ? URL(string: raw)!.host! : raw }
}
