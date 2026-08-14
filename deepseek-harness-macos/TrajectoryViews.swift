import AppKit
import SwiftUI

struct JobListMenu: View {
    let jobs: [BackgroundJob]
    @State private var now = Date()
    @State private var open = false

    var body: some View {
        Button { now = Date(); open.toggle() } label: {
            HStack(spacing: 3) {
                if liveCount > 0 { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                Text(liveCount > 0 ? "\(liveCount) 个后台任务" : "\(jobs.count) 个任务").padding(.horizontal, 5)
                Image(systemName: "chevron.down").font(.system(size: 8)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 12)).foregroundStyle(.tertiary).frame(minHeight: 28)
        }.buttonStyle(.plain).fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(ordered) { job in
                        HStack(spacing: 8) {
                            Image(systemName: dotSymbol(job.status)).font(.system(size: 8)).foregroundStyle(dotColor(job.status)).frame(width: 8)
                            Text(job.kind).font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).frame(height: 18).background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                            Text(job.label).font(.system(size: 13, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(job.detail ?? statusLabel(job.status)).lineLimit(1).frame(maxWidth: 100, alignment: .trailing)
                            Text(duration(job)).monospacedDigit()
                        }
                        .font(.system(size: 11)).foregroundStyle(job.isLive ? .primary : .tertiary)
                        .padding(.horizontal, 8).frame(minHeight: 32)
                    }
                }.padding(4)
            }.frame(width: 336, height: min(420, CGFloat(ordered.count * 33 + 8)))
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1)); now = Date()
            }
        }
    }

    private var liveCount: Int { jobs.filter(\.isLive).count }
    private var ordered: [BackgroundJob] {
        jobs.sorted { left, right in
            if left.isLive != right.isLive { return left.isLive }
            if left.isLive { return left.startedAt < right.startedAt }
            return (left.finishedAt ?? left.startedAt) > (right.finishedAt ?? right.startedAt)
        }
    }
    private func statusLabel(_ value: String) -> String { switch value { case "running": "运行中"; case "stopping": "正在停止"; case "completed": "已完成"; case "killed": "已终止"; default: "失败" } }
    private func dotSymbol(_ value: String) -> String { switch value { case "completed": "checkmark.circle.fill"; case "failed": "xmark.circle.fill"; case "running": "circle.fill"; default: "exclamationmark.circle.fill" } }
    private func dotColor(_ value: String) -> Color { switch value { case "completed": .green; case "failed": .red; case "running": .accentColor; default: .orange } }
    private func duration(_ job: BackgroundJob) -> String {
        let seconds = max(0, Int((job.finishedAt ?? now).timeIntervalSince(job.startedAt)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, remainder = seconds % 60
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        if minutes > 0 { return "\(minutes)分 \(remainder)秒" }
        return "\(remainder)秒"
    }
}

struct ProducedFilesRow: View {
    @EnvironmentObject private var model: AppModel
    let paths: [String]
    private let limit = 6
    @State private var laneWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("生成的文件").foregroundStyle(.tertiary)
                fileLane(count: shownCount).background(GeometryReader { proxy in
                    Color.clear.onAppear { laneWidth = proxy.size.width }.onChange(of: proxy.size.width) { laneWidth = $0 }
                })
            }
            if shownCount < paths.count {
                Button("在文件夹中显示") { revealFolder() }.buttonStyle(.plain).foregroundStyle(.tertiary).padding(.leading, 78)
            }
        }.font(.system(size: 13)).padding(.top, 16)
    }

    private var shownCount: Int {
        let upper = min(limit, paths.count)
        guard laneWidth > 0 else { return upper }
        let font = NSFont.systemFont(ofSize: 13)
        func width(_ text: String) -> CGFloat { min(320, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16) }
        for count in stride(from: upper, through: 0, by: -1) {
            let chipWidth = paths.prefix(count).reduce(CGFloat.zero) { $0 + width(URL(fileURLWithPath: $1).lastPathComponent) }
            let hidden = paths.count - count
            let more = hidden == 0 ? 0 : width(hidden == 1 ? "以及另外 1 个" : "以及另外 \(hidden) 个") - 16
            let items = count + (hidden > 0 ? 1 : 0)
            if chipWidth + more + CGFloat(max(0, items - 1) * 8) <= laneWidth { return count }
        }
        return 0
    }

    private func fileLane(count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(paths.prefix(count)), id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) { open(path) }
                    .buttonStyle(.plain).lineLimit(1).padding(.horizontal, 8).frame(height: 22)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6)).help(path)
            }
            if paths.count > count { Text(paths.count - count == 1 ? "以及另外 1 个" : "以及另外 \(paths.count - count) 个").foregroundStyle(.tertiary).fixedSize() }
            Spacer(minLength: 0)
        }
    }

    private func open(_ path: String) {
        guard let cwd = model.current?.cwd else { return }
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
        NSWorkspace.shared.open(url)
    }
    private func revealFolder() {
        guard let cwd = model.current?.cwd else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    }
}

struct TrajectoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var collapsedTurns = Set<Int>()
    @State private var collapsedAssistants = Set<String>()
    @State private var actualDuration = false
    @State private var selected: TrajectoryCell?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            timeline
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        tableHeader
                        ForEach(filteredTurns) { turn in turnSection(turn) }
                    }
                }.frame(minWidth: 470)
                if let selected { inspector(selected).frame(minWidth: 230, idealWidth: 300, maxWidth: 400) }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button { actualDuration.toggle() } label: { Label("时长", systemImage: "clock") }.buttonStyle(.plain).foregroundStyle(actualDuration ? Color.accentColor : .secondary)
            Button { toggleAllTurns() } label: { Text(collapsedTurns.count == model.trajectory.count ? "⊞ Turns" : "⊟ Turns") }.buttonStyle(.plain)
            Button { toggleAllAssistants() } label: { Text(allAssistantsCollapsed ? "⊞ Calls" : "⊟ Calls") }.buttonStyle(.plain)
            Spacer()
            HStack(spacing: 5) { Image(systemName: "magnifyingglass").font(.system(size: 10)); TextField("搜索记录", text: $query).textFieldStyle(.plain).frame(width: 150) }
                .padding(.horizontal, 8).frame(height: 25).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 6).frame(height: 32).background(Color(nsColor: .windowBackgroundColor)).overlay(alignment: .bottom) { Divider() }
    }

    private var timeline: some View {
        GeometryReader { proxy in
            let cells = allCells
            HStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                    Text("Input").offset(y: 5)
                    Text("Model").offset(y: 19)
                    Text("Tools").offset(y: 33)
                }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.trailing, 3).frame(width: 44)
                Divider()
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(model.trajectory.dropFirst()) { turn in
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 50)
                            .offset(x: timelineX(for: turn.groups.first?.cells.first, cells: cells, width: proxy.size.width - 45))
                    }
                    ForEach(cells) { cell in
                        RoundedRectangle(cornerRadius: 1).fill(timelineColor(cell).opacity(cell.isError ? 1 : 0.88))
                            .frame(width: timelineWidth(cell, total: cells, available: proxy.size.width - 45), height: 8)
                            .offset(x: timelineX(for: cell, cells: cells, width: proxy.size.width - 45), y: laneY(cell.kind))
                            .help("#\(cell.index) \(cell.kind.rawValue) · \(duration(cell.duration))")
                            .onTapGesture { selected = cell }
                    }
                }
            }
        }.frame(height: 50).background(Color(nsColor: .controlBackgroundColor)).overlay(alignment: .bottom) { Divider() }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Event").frame(width: 122, alignment: .trailing).padding(.trailing, 8)
            Text("Content").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            Text("Input").frame(width: 58); Text("Output").frame(width: 58); Text("Think").frame(width: 58); Text("Time").frame(width: 72)
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary).frame(height: 30).background(.regularMaterial)
    }

    private func turnSection(_ turn: TrajectoryTurn) -> some View {
        VStack(spacing: 0) {
            if collapsedTurns.contains(turn.turn) {
                Button { toggleTurn(turn.turn) } label: {
                    HStack(spacing: 7) { Text("Turn \(turn.turn)").font(.system(size: 8, design: .monospaced)); Text("…"); Text("\(turn.groups.flatMap(\.cells).count) records").foregroundStyle(.tertiary); Spacer() }
                        .padding(.horizontal, 5).frame(height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).background(Color.primary.opacity(0.025))
            } else {
                let cells = turn.groups.flatMap { visibleCells($0) }
                ForEach(Array(cells.enumerated()), id: \.element.id) { offset, cell in
                    cellRow(cell, turn: turn.turn, isFirst: offset == 0, isLast: offset == cells.count - 1)
                }
            }
        }
    }

    private func cellRow(_ cell: TrajectoryCell, turn: Int, isFirst: Bool, isLast: Bool) -> some View {
        Button { selected = cell } label: {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if isFirst {
                        Button("Turn \(turn)") { toggleTurn(turn) }.buttonStyle(.plain).font(.system(size: 8, design: .monospaced))
                            .padding(.horizontal, 5).frame(height: 12).background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 2))
                    } else { Color.clear.frame(width: 31, height: 1) }
                    Text("#\(cell.index)").foregroundStyle(.tertiary).frame(width: 27, alignment: .trailing)
                    Text(cell.kind.rawValue).font(.system(size: 10, weight: .semibold)).foregroundStyle(cell.isError ? .red : color(cell.kind)).lineLimit(1)
                }.frame(width: 122, alignment: .trailing).padding(.trailing, 8)
                Text(cell.summary.isEmpty ? "—" : cell.summary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                metric(cell.usage?.input).frame(width: 58); metric(cell.usage?.output).frame(width: 58); metric(cell.usage?.think).frame(width: 58)
                Text(duration(cell.duration)).foregroundStyle(.tertiary).frame(width: 72)
            }.font(.system(size: 12)).frame(height: 30).contentShape(Rectangle())
                .background(selected?.id == cell.id ? Color.accentColor.opacity(0.1) : .clear)
        }.buttonStyle(.plain).overlay(alignment: .leading) { Rectangle().fill(cell.isError ? Color.red.opacity(0.35) : Color.blue.opacity(0.2)).frame(width: 2).opacity(isLast ? 0.7 : 1) }
            .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    private func inspector(_ cell: TrajectoryCell) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("#\(cell.index) \(cell.kind.rawValue)").font(.headline); Spacer(); Button { selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            Text(cell.summary).font(.callout).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                GridRow { Text("Seq").foregroundStyle(.tertiary); Text("\(cell.seq)") }
                GridRow { Text("Started").foregroundStyle(.tertiary); Text(cell.startedAt?.formatted(date: .omitted, time: .standard) ?? "—") }
                GridRow { Text("Duration").foregroundStyle(.tertiary); Text(duration(cell.duration)) }
                if let callId = cell.callId { GridRow { Text("Call ID").foregroundStyle(.tertiary); Text(callId).lineLimit(1).help(callId) } }
            }.font(.caption.monospaced())
            ScrollView { Text(cell.detail.isEmpty ? "没有详细内容" : cell.detail).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor))
    }

    private var allCells: [TrajectoryCell] { model.trajectory.flatMap(\.groups).flatMap(\.cells) }
    private var filteredTurns: [TrajectoryTurn] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.trajectory }
        return model.trajectory.compactMap { turn in
            let groups = turn.groups.compactMap { group -> TrajectoryGroup? in
                let cells = group.cells.filter { $0.summary.localizedCaseInsensitiveContains(needle) || $0.detail.localizedCaseInsensitiveContains(needle) || $0.kind.rawValue.localizedCaseInsensitiveContains(needle) }
                return cells.isEmpty ? nil : TrajectoryGroup(turn: group.turn, step: group.step, cells: cells)
            }
            return groups.isEmpty ? nil : TrajectoryTurn(turn: turn.turn, groups: groups)
        }
    }
    private var allAssistantsCollapsed: Bool {
        let assistants = allCells.filter { $0.kind == .assistant && hasFollowingTools($0) }
        return !assistants.isEmpty && assistants.allSatisfy { collapsedAssistants.contains($0.id) }
    }
    private func visibleCells(_ group: TrajectoryGroup) -> [TrajectoryCell] {
        var result: [TrajectoryCell] = [], hideTools = false
        for cell in group.cells {
            if cell.kind == .assistant { hideTools = collapsedAssistants.contains(cell.id); result.append(cell); continue }
            if hideTools && (cell.kind == .tool || cell.kind == .subtool) { continue }
            hideTools = false; result.append(cell)
        }
        return result
    }
    private func hasFollowingTools(_ cell: TrajectoryCell) -> Bool { allCells.drop { $0.id != cell.id }.dropFirst().first.map { $0.kind == .tool || $0.kind == .subtool } ?? false }
    private func toggleAllTurns() { collapsedTurns = collapsedTurns.count == model.trajectory.count ? [] : Set(model.trajectory.map(\.turn)) }
    private func toggleTurn(_ turn: Int) { if collapsedTurns.remove(turn) == nil { collapsedTurns.insert(turn) } }
    private func toggleAllAssistants() { collapsedAssistants = allAssistantsCollapsed ? [] : Set(allCells.filter { $0.kind == .assistant && hasFollowingTools($0) }.map(\.id)) }
    private func metric(_ value: Int?) -> some View { Text(value.map(compactNumber) ?? "—").foregroundStyle(.tertiary) }
    private func compactNumber(_ value: Int) -> String { value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1_000 ? String(format: "%.1fK", Double(value) / 1_000) : "\(value)" }
    private func duration(_ value: TimeInterval?) -> String { guard let value else { return "—" }; return value < 1 ? "\(Int((value * 1000).rounded())) ms" : String(format: "%.1f s", value) }
    private func timelineWidth(_ cell: TrajectoryCell, total: [TrajectoryCell], available: CGFloat) -> CGFloat { if !actualDuration { return 8 }; let sum = total.reduce(0.0) { $0 + max(0.04, $1.duration ?? 0.04) }; return max(2, available * CGFloat(max(0.04, cell.duration ?? 0.04) / sum)) }
    private func timelineX(for cell: TrajectoryCell?, cells: [TrajectoryCell], width: CGFloat) -> CGFloat {
        guard let cell, let offset = cells.firstIndex(where: { $0.id == cell.id }) else { return 0 }
        if !actualDuration { return max(0, (width - 8) * CGFloat(offset) / CGFloat(max(1, cells.count - 1))) }
        let before = cells.prefix(offset).reduce(0.0) { $0 + max(0.04, $1.duration ?? 0.04) }
        let sum = cells.reduce(0.0) { $0 + max(0.04, $1.duration ?? 0.04) }
        return width * CGFloat(before / max(0.04, sum))
    }
    private func laneY(_ kind: TrajectoryKind) -> CGFloat { switch kind { case .assistant: 21; case .tool, .subtool: 35; default: 7 } }
    private func timelineColor(_ cell: TrajectoryCell) -> Color { switch cell.kind { case .user: .blue; case .context: .green; case .assistant: .purple; case .tool, .subtool: .orange; default: .secondary } }
    private func icon(_ kind: TrajectoryKind) -> String { switch kind { case .system: "gearshape"; case .user: "person"; case .context: "info.circle"; case .compacted: "arrow.triangle.2.circlepath"; case .assistant: "sparkles"; case .tool: "wrench"; case .subtool: "arrow.turn.down.right" } }
    private func color(_ kind: TrajectoryKind) -> Color { switch kind { case .system: .gray; case .user: .blue; case .context: .orange; case .compacted: .purple; case .assistant: .accentColor; case .tool: .green; case .subtool: .teal } }
}
