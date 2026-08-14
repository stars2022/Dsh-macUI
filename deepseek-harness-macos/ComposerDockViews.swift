import SwiftUI

struct TodoDockView: View {
    let todos: [TodoItem]
    @State private var collapsed = true

    var body: some View {
        if !todos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 10) {
                        DeepSeekIcon(kind: .checklist, size: 14).frame(width: 14)
                        Text("计划").fontWeight(.medium)
                        Text(progress).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        DeepSeekIcon(kind: .chevronDown, size: 14)
                            .rotationEffect(.degrees(collapsed ? 180 : 0))
                    }.frame(height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if !collapsed {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(todos) { item in
                                HStack(spacing: 10) {
                                    TodoStatusGlyph(status: item.status)
                                    Text(item.content).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }.frame(height: 20)
                            }
                        }
                    }.frame(maxHeight: 180)
                }
            }
            .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(nsColor: Theme.tip), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: Theme.borderL1)))
        }
    }

    private var progress: String {
        let done = todos.filter { $0.status == "completed" }.count
        let active = todos.filter { $0.status == "in_progress" }.count
        let pending = todos.count - done - active
        return [(done > 0 ? "已完成 \(done)" : nil), (active > 0 ? "进行中 \(active)" : nil),
                (pending > 0 ? "待处理 \(pending)" : nil)].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct TodoStatusGlyph: View {
    let status: String
    var body: some View {
        Group {
            if status == "completed" { TodoCompletedGlyph() }
            else if status == "in_progress" { TodoProgressGlyph() }
            else { TodoPendingGlyph() }
        }.frame(width: 16, height: 16)
    }
}

private struct TodoCompletedGlyph: View {
    private static let checkPath = "M10.9631 5.71411L7.70154 8.97571C7.48011 9.19714 7.27736 9.40099 7.09229 9.54993C6.89742 9.70669 6.66314 9.85279 6.3634 9.90027C6.2049 9.92534 6.04339 9.92534 5.88489 9.90027C5.58515 9.85279 5.35087 9.70669 5.15601 9.54993C4.97093 9.40099 4.76818 9.19714 4.54675 8.97571L3.03516 7.46411L3.96313 6.53613L5.47473 8.04773C5.7169 8.28989 5.86196 8.43389 5.97888 8.52795C6.08597 8.61409 6.10875 8.60701 6.08997 8.604C6.11259 8.60758 6.13571 8.60758 6.15833 8.604C6.13954 8.60701 6.16232 8.61409 6.26941 8.52795C6.38633 8.43389 6.53139 8.28989 6.77356 8.04773L10.0352 4.78613L10.9631 5.71411Z"
    var body: some View {
        Canvas { context, _ in
            let circle = Path(ellipseIn: CGRect(x: 0.6, y: 0.6, width: 12.8, height: 12.8))
            context.stroke(circle, with: .foreground, lineWidth: 1.2)
            context.fill(DeepSeekIcon.svgPath(Self.checkPath), with: .foreground)
        }
        .frame(width: 14, height: 14)
        .foregroundStyle(Color(nsColor: Theme.stateSuccess))
    }
}

private struct TodoProgressGlyph: View {
    @State private var rotation = 0.0
    var body: some View {
        Canvas { context, _ in
            let circle = Path(ellipseIn: CGRect(x: 0.6, y: 0.6, width: 12.8, height: 12.8))
            context.stroke(circle, with: .linearGradient(
                Gradient(colors: [Color(nsColor: Theme.business), Color(nsColor: Theme.business).opacity(0)]),
                startPoint: CGPoint(x: 2.5, y: 12), endPoint: CGPoint(x: 10.5, y: 3.5)), lineWidth: 1.2)
        }
        .frame(width: 14, height: 14)
        .rotationEffect(.degrees(rotation))
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { rotation = 360 } }
    }
}

private struct TodoPendingGlyph: View {
    var body: some View {
        Circle()
            .stroke(Color(nsColor: .tertiaryLabelColor), style: StrokeStyle(lineWidth: 1.2, dash: [2.4, 2.4]))
            .frame(width: 12.8, height: 12.8)
    }
}

struct GoalDockView: View {
    @EnvironmentObject private var model: AppModel
    let goal: GoalSnapshot
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if goal.phase != "complete" {
            HStack(spacing: 10) {
                DeepSeekIcon(kind: .goal, size: 14).foregroundStyle(.tertiary)
                if editing {
                    TextField("目标", text: $draft).textFieldStyle(.roundedBorder).onSubmit(save)
                    dockButton(.check, help: "保存", action: save).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    dockButton(.close, help: "取消") { editing = false }
                } else {
                    Text(phaseLabel).fontWeight(.medium)
                    Text(goal.objective).foregroundStyle(.secondary).lineLimit(1).help(goal.blockedReason ?? goal.objective)
                    Spacer(minLength: 0)
                    if goal.phase == "active" { dockButton(.pause, help: "暂停") { model.mutateGoal("goal.pause") } }
                    if goal.phase == "paused" { dockButton(.play, help: "继续") { model.mutateGoal("goal.resume") } }
                    dockButton(.edit, help: "编辑") { draft = goal.objective; editing = true }
                    dockButton(.trash, help: "清除") { model.mutateGoal("goal.clear") }
                }
            }
            .font(.system(size: 13)).padding(.leading, 12).padding(.trailing, 5).frame(height: 36)
            .background(Color(nsColor: Theme.tip), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: Theme.borderL1)))
            .disabled(model.dockBusy)
        }
    }

    private var phaseLabel: String { switch goal.phase { case "paused": "已暂停"; case "blocked": "已阻塞"; default: "目标" } }
    private func save() { let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { model.mutateGoal("goal.edit", objective: text); editing = false } }
    private func dockButton(_ icon: DeepSeekIconKind, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { DeepSeekIcon(kind: icon, size: 14).frame(width: 28, height: 28).contentShape(Circle()) }.buttonStyle(.plain).help(help)
    }
}

struct QueueDockView: View {
    @EnvironmentObject private var model: AppModel
    let queue: [QueuedMessage]
    @State private var collapsed = true
    @State private var editingId: String?
    @State private var editText = ""

    var body: some View {
        if !queue.isEmpty {
            VStack(spacing: 0) {
                if queue.count > 1 {
                    Button { collapsed.toggle() } label: {
                        HStack(spacing: 10) { Image(systemName: "tray.full"); Text("已排队 \(queue.count) 条").fontWeight(.medium); Spacer(); Image(systemName: collapsed ? "chevron.up" : "chevron.down") }
                            .frame(height: 36).padding(.horizontal, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(editingId != nil)
                }
                if queue.count == 1 || !collapsed || editingId != nil {
                    ForEach(queue) { item in row(item) }
                }
            }
            .font(.system(size: 13)).padding(.top, 2)
            .background(Color(nsColor: .controlBackgroundColor), in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12).stroke(Color.primary.opacity(0.12)))
            .disabled(model.dockBusy)
        }
    }

    private func row(_ item: QueuedMessage) -> some View {
        HStack(spacing: 10) {
            if queue.count == 1 { Image(systemName: "tray.full").foregroundStyle(.tertiary) }
            if editingId == item.id {
                TextField("编辑排队消息", text: $editText).textFieldStyle(.roundedBorder).onSubmit { save(item) }
            } else { Text(item.preview).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 0) }
            if editingId == item.id {
                smallButton("checkmark", "保存") { save(item) }
                smallButton("xmark", "取消") { editingId = nil }
            } else {
                smallButton("pencil", "编辑") { if let text = item.text { editText = text; editingId = item.id } }.disabled(item.text == nil)
                smallButton("trash", "移除") { model.updateQueue(item, action: ["kind": "remove"]) }
                smallButton("paperplane", "插话") { model.updateQueue(item, action: ["kind": "steer"]) }.disabled(model.current?.running != true)
            }
        }.frame(height: 36).padding(.leading, 12).padding(.trailing, 5)
    }

    private func save(_ item: QueuedMessage) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.updateQueue(item, action: ["kind": "edit", "content": [["type": "text", "text": text]]]); editingId = nil
    }
    private func smallButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28).contentShape(Circle()) }.buttonStyle(.plain).help(help)
    }
}

struct PendingSteeringView: View {
    let item: QueuedMessage
    var body: some View {
        HStack { Spacer(minLength: 80); Text(item.preview).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 22)).opacity(0.72) }
    }
}
