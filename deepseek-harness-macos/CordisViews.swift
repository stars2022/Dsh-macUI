import SwiftUI

private let cordisAccent = Color(nsColor: Theme.business)

struct CordisToolRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            switch tool.cordis {
            case let .define(card): CordisDefineRow(tool: tool, card: card, expanded: $expanded, hovering: hovering)
            case let .run(card): CordisRunRow(tool: tool, card: card, hovering: hovering)
            case let .action(card): CordisActionRow(tool: tool, card: card, hovering: hovering)
            case nil: EmptyView()
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct CordisDefineRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    let card: CordisDefineCard
    @Binding var expanded: Bool
    let hovering: Bool
    @State private var selected: Source = .client

    private enum Source { case client, host }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if expandable { withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() } } } label: {
                HStack(spacing: 0) {
                    leading.frame(width: 16, height: 16).padding(.trailing, 6)
                    Text("注册 Cordis 插件").fontWeight(.medium).foregroundStyle(cordisAccent)
                    Circle().fill(cordisAccent).frame(width: 2, height: 2).padding(.horizontal, 8)
                    Text(card.errorSummary ?? card.name ?? tool.id)
                        .foregroundStyle(card.errorSummary == nil ? Color.secondary : Color.red)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if card.errorSummary == nil {
                        Text(card.purpose ?? "(未填写用途)")
                            .font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, 8)
                    }
                    Spacer(minLength: 0)
                    if card.pluginId != nil, let reading = model.cordisReading(for: tool) {
                        Text(reading).font(.system(size: 12)).foregroundStyle(statusColor(reading)).padding(.leading, 8)
                    }
                }
                .font(.system(size: 14)).frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!expandable)
            if expanded && expandable {
                VStack(alignment: .leading, spacing: 0) {
                    if activeCode != nil { sourceCard }
                    if let output = card.output {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("结果").font(.system(size: 11, weight: .medium)).tracking(0.44)
                                .foregroundStyle(.tertiary).textCase(.uppercase)
                            ScrollView(.vertical) {
                                Text(output).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(card.state == .error ? Color.red : Color.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                            }
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        }.frame(maxHeight: 260).padding(.leading, 4).padding(.vertical, 4)
                    }
                    if card.pluginId != nil {
                        Text("运行控制在左下角设置上方的 Cordis 面板")
                            .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 8).padding(.vertical, 4)
                    }
                    inspectButton
                }
            }
        }
        .accessibilityLabel(card.state == .running ? "正在定义插件" : card.state == .error ? "定义失败" : card.state == .stopped ? "定义已中断" : "注册 Cordis 插件")
    }

    private var leading: some View {
        Group {
            if expanded || hovering, expandable { DeepSeekIcon(kind: .chevronDown, size: 14) }
            else if card.state == .error { Circle().fill(Color.red).frame(width: 8, height: 8) }
            else if card.state == .stopped { Circle().fill(Color.orange).frame(width: 8, height: 8) }
            else { DeepSeekIcon(kind: .code, size: 14) }
        }.foregroundStyle(card.state == .error ? Color.red : cordisAccent)
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sourceButton("Client", source: .client, available: card.clientCode != nil)
                sourceButton("Host", source: .host, available: card.hostCode != nil)
                Spacer()
            }.frame(height: 32).overlay(alignment: .bottom) { Divider() }
            ScrollView([.horizontal, .vertical]) {
                Text(NativeSyntaxHighlighter.attributed(activeCode ?? "", language: "javascript"))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.frame(maxHeight: 260)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .padding(.leading, 4).padding(.vertical, 4)
    }

    private func sourceButton(_ label: String, source: Source, available: Bool) -> some View {
        Button { selected = source } label: {
            Text(label).font(.system(size: 13)).foregroundStyle(activeSource == source ? cordisAccent : Color.secondary)
                .frame(height: 32).padding(.horizontal, 10)
                .overlay(alignment: .bottom) {
                    if activeSource == source { RoundedRectangle(cornerRadius: 1).fill(cordisAccent).frame(height: 2).padding(.horizontal, 10) }
                }
        }.buttonStyle(.plain).disabled(!available).opacity(available ? 1 : 0.4)
    }

    private var activeSource: Source {
        if selected == .client, card.clientCode != nil { return .client }
        if selected == .host, card.hostCode != nil { return .host }
        return card.clientCode != nil ? .client : .host
    }
    private var activeCode: String? { activeSource == .client ? card.clientCode : card.hostCode }
    private var expandable: Bool { card.hostCode != nil || card.clientCode != nil || card.output != nil }
    private var inspectButton: some View {
        Button { model.showTool(tool) } label: { HStack(spacing: 4) { DeepSeekIcon(kind: .inspect, size: 12); Text("Inspect") } }
            .buttonStyle(.bordered).controlSize(.mini).opacity(hovering ? 1 : 0).padding(.leading, 4).padding(.vertical, 2)
    }
}

private struct CordisRunRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    let card: CordisRunCard
    let hovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                stateLeading(tool.state, normal: .code).frame(width: 16, height: 16).padding(.trailing, 8)
                Text(card.mode == "update" ? "更新 Cordis 插件" : "运行 Cordis 插件")
                    .fontWeight(.medium).foregroundStyle(cordisAccent)
                Circle().fill(cordisAccent).frame(width: 2, height: 2).padding(.horizontal, 8)
                Text(card.errorSummary ?? summary).foregroundStyle(card.errorSummary == nil ? Color.secondary : Color.red).lineLimit(1)
                Spacer(minLength: 0)
                if let reading = model.cordisReading(for: tool) {
                    Text(reading).font(.system(size: 12)).foregroundStyle(statusColor(reading)).padding(.leading, 8)
                }
                inspect
            }.font(.system(size: 14)).frame(minHeight: 32)
                .overlay { if tool.state == .running { CordisSweepHighlight() } }.clipped()
            if let message = model.cordisRunMessage(for: tool) {
                Text(message).font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            } else if let output = card.output { outputBlock(output, error: card.state == .error) }
        }
    }

    private var summary: String {
        guard let plugin = card.pluginId else { return tool.id }
        return card.packageId.map { "\(plugin) · \($0)" } ?? plugin
    }
    private var inspect: some View {
        Button { model.showTool(tool) } label: { DeepSeekIcon(kind: .inspect, size: 12).frame(width: 24, height: 24) }
            .buttonStyle(.plain).opacity(hovering ? 1 : 0).padding(.leading, 4)
    }
}

private struct CordisActionRow: View {
    @EnvironmentObject private var model: AppModel
    let tool: ToolCall
    let card: CordisActionCard
    let hovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                stateLeading(tool.state, normal: tool.name == "cordis_undefine" ? .trash : .stop)
                    .frame(width: 16, height: 16).padding(.trailing, 8)
                Text(tool.name == "cordis_undefine" ? "移除 Cordis 插件" : "停止 Cordis 插件")
                    .fontWeight(.medium).foregroundStyle(cordisAccent)
                Circle().fill(cordisAccent).frame(width: 2, height: 2).padding(.horizontal, 8)
                Text(card.errorSummary ?? card.pluginId ?? tool.id)
                    .foregroundStyle(card.errorSummary == nil ? Color.secondary : Color.red).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.showTool(tool) } label: { DeepSeekIcon(kind: .inspect, size: 12).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).opacity(hovering ? 1 : 0).padding(.leading, 4)
            }.font(.system(size: 14)).frame(minHeight: 32)
                .overlay { if tool.state == .running { CordisSweepHighlight() } }.clipped()
            if let output = card.output { outputBlock(output, error: card.state == .error) }
        }
    }
}

@ViewBuilder private func stateLeading(_ state: ToolState, normal: DeepSeekIconKind) -> some View {
    if state == .error { Circle().fill(Color.red).frame(width: 8, height: 8) }
    else if state == .stopped { Circle().fill(Color.orange).frame(width: 8, height: 8) }
    else { DeepSeekIcon(kind: normal, size: 14).foregroundStyle(cordisAccent) }
}

private func outputBlock(_ output: String, error: Bool) -> some View {
    Text(output).font(.system(size: 12, design: .monospaced))
        .foregroundStyle(error ? Color.red : Color.secondary).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
}

private func statusColor(_ reading: String) -> Color {
    switch reading {
    case "运行中": return .green
    case "待审批", "Client 待激活": return .orange
    case "运行失败": return .red
    default: return Color(nsColor: .tertiaryLabelColor)
    }
}

private struct CordisSweepHighlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { timeline in
                GeometryReader { proxy in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
                    let moving = min(1, cycle / 0.9)
                    let eased = 1 - pow(1 - moving, 3)
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.60), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 300).offset(x: -300 + (proxy.size.width + 300) * eased)
                }
            }.allowsHitTesting(false)
        }
    }
}
