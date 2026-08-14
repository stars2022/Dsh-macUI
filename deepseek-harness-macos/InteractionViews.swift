import SwiftUI

struct InteractionComposer: View {
    let interaction: PendingInteraction

    var body: some View {
        switch interaction {
        case let .approval(request): ApprovalComposer(request: request)
        case let .question(request): QuestionComposer(request: request)
        }
    }
}

private struct ApprovalComposer: View {
    @EnvironmentObject private var model: AppModel
    let request: ApprovalRequest

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("等待审批")
                Spacer()
            }
            .font(.system(size: 13)).foregroundStyle(Color.orange)
            .padding(.horizontal, 16).frame(height: 38).background(Color.orange.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.reason ?? "工具 \(request.toolName) 请求越权执行")
                        .font(.system(size: 15, weight: .medium))
                    if let command { Text(command).font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 12)
            }.frame(maxHeight: 150)
            HStack(spacing: 8) {
                Spacer()
                Button("拒绝") { model.answerApproval(request, outcome: "rejected") }
                    .buttonStyle(.bordered).disabled(model.interactionBusy)
                Button("允许一次") { model.answerApproval(request, outcome: "allowed-once") }
                    .buttonStyle(.borderedProminent).disabled(model.interactionBusy)
            }.padding(.horizontal, 16).padding(.vertical, 14)
        }
        .frame(maxWidth: 748)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.orange.opacity(0.42)))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    private var command: String? {
        guard let callId = request.callId,
              let item = model.history.first(where: { if case let .tool(tool) = $0.kind { return tool.id == callId }; return false }),
              case let .tool(tool) = item.kind,
              let data = tool.arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return args["command"] as? String
    }
}

private struct QuestionDraft {
    var selected: [String] = []
    var custom = ""
    var skipped = false
}

private struct QuestionComposer: View {
    @EnvironmentObject private var model: AppModel
    let request: QuestionRequest
    @State private var index = 0
    @State private var drafts: [QuestionDraft]
    @State private var feedback: String?

    init(request: QuestionRequest) {
        self.request = request
        _drafts = State(initialValue: request.questions.map { _ in QuestionDraft() })
    }

    var body: some View {
        if let review = planReview {
            PlanReviewComposer(request: request, question: review)
        } else if request.questions.isEmpty {
            EmptyQuestionComposer(request: request)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if let header = question.header { Text(header).font(.system(size: 11)).foregroundStyle(.tertiary) }
                    Text(question.question).font(.system(size: 16, weight: .medium))
                }
                Spacer(minLength: 8)
                Button { model.cancelQuestions(request) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).disabled(model.interactionBusy)
            }.padding(.leading, 24).padding(.trailing, 16).padding(.top, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if let detail = question.detail { Text(markdown(detail)).font(.system(size: 14)).padding(.horizontal, 2).textSelection(.enabled) }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        optionButton(option, number: optionIndex + 1)
                    }
                    customInput
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            }.frame(maxHeight: 330)
            HStack(spacing: 8) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).disabled(index == 0 || model.interactionBusy)
                Text("\(index + 1) / \(request.questions.count)").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Button { move(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(index == request.questions.count - 1 || model.interactionBusy)
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
                Button("跳过本题") { skip() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.interactionBusy)
                if question.multiSelect || question.options.isEmpty || index == request.questions.count - 1 {
                    Button(index == request.questions.count - 1 ? "提交" : "下一题") { continueFlow() }
                        .buttonStyle(.borderedProminent).disabled(model.interactionBusy)
                }
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10)
        }
        .frame(maxWidth: 748)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    private var question: QuestionItem { request.questions[index] }
    private var draft: QuestionDraft { drafts[index] }
    private var answered: Bool { !draft.selected.isEmpty || !draft.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func optionButton(_ option: QuestionOption, number: Int) -> some View {
        let selected = draft.selected.contains(option.label)
        let display = recommended(option.label)
        return Button { choose(option.label) } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if question.multiSelect { Image(systemName: selected ? "checkmark.square.fill" : "square") }
                    else { Text("\(number)").font(.system(size: 12, weight: .medium)).frame(width: 20, height: 20).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6)) }
                }.frame(width: 20, height: 24).foregroundStyle(selected ? Color.primary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(display.label).font(.system(size: 14, weight: .medium))
                        if display.recommended { Text("推荐").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor).padding(.horizontal, 4).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6)) }
                    }
                    if let description = option.description { Text(description).font(.system(size: 13)).foregroundStyle(.tertiary) }
                }
                Spacer()
            }.padding(.horizontal, 8).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected && !question.multiSelect ? Color.secondary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private var customInput: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: question.multiSelect ? (draft.custom.isEmpty ? "square" : "checkmark.square.fill") : "square.and.pencil")
                .frame(width: 20, height: 24).foregroundStyle(.secondary)
            TextField("输入你的答案", text: Binding(get: { drafts[index].custom }, set: { value in
                drafts[index].custom = value; drafts[index].skipped = false
                if !question.multiSelect { drafts[index].selected = [] }
                feedback = nil
            }), axis: question.options.isEmpty ? .vertical : .horizontal)
                .textFieldStyle(.plain).lineLimit(question.options.isEmpty ? 2...5 : 1...1)
                .padding(.vertical, question.options.isEmpty ? 6 : 1)
        }.padding(.horizontal, 8).padding(.vertical, 8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func choose(_ label: String) {
        feedback = nil; drafts[index].skipped = false
        if question.multiSelect {
            if drafts[index].selected.contains(label) { drafts[index].selected.removeAll { $0 == label } }
            else { drafts[index].selected.append(label) }
        } else {
            drafts[index].selected = [label]; drafts[index].custom = ""
            if index < request.questions.count - 1 { index += 1 }
            else { submitIfComplete() }
        }
    }
    private func move(_ delta: Int) { index = min(max(0, index + delta), request.questions.count - 1); feedback = nil }
    private func continueFlow() { guard answered else { feedback = "请回答或跳过本题"; return }; index < request.questions.count - 1 ? move(1) : submitIfComplete() }
    private func skip() { drafts[index] = QuestionDraft(skipped: true); index < request.questions.count - 1 ? move(1) : submitIfComplete() }
    private func submitIfComplete() {
        if let missing = drafts.firstIndex(where: { !$0.skipped && $0.selected.isEmpty && $0.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            index = missing; feedback = "请完成所有问题或逐题跳过"; return
        }
        let answers: [[String: Any]] = request.questions.enumerated().map { i, item in
            let value = drafts[i]
            var answer: [String: Any] = ["id": item.id, "selected": value.skipped ? [] : (value.custom.isEmpty || item.multiSelect ? value.selected : [])]
            let custom = value.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.skipped && !custom.isEmpty { answer["custom"] = custom }
            return answer
        }
        model.answerQuestions(request, answers: answers)
    }
    private var planReview: QuestionItem? {
        guard request.questions.count == 1, let item = request.questions.first,
              item.intent?.kind == "plan-review", item.detail != nil, !item.multiSelect,
              item.options.count <= 2, let approve = item.intent?.approve,
              item.options.contains(where: { $0.label == approve }) else { return nil }
        return item
    }
    private func recommended(_ raw: String) -> (label: String, recommended: Bool) {
        let pattern = #"\s*(?:\((?:recommended|推荐)\)|（(?:recommended|推荐)）)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil else { return (raw, false) }
        return (regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: ""), true)
    }
    private func markdown(_ value: String) -> AttributedString { (try? AttributedString(markdown: value)) ?? AttributedString(value) }
}

private struct EmptyQuestionComposer: View {
    @EnvironmentObject private var model: AppModel
    let request: QuestionRequest
    var body: some View {
        HStack { Text("智能体正在等待回答，但请求中没有问题。"); Spacer(); Button("关闭") { model.cancelQuestions(request) }.buttonStyle(.bordered) }
            .padding(18).frame(maxWidth: 748).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct PlanReviewComposer: View {
    @EnvironmentObject private var model: AppModel
    let request: QuestionRequest
    let question: QuestionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(question.question).font(.system(size: 16, weight: .medium)); Spacer(); Button { model.cancelQuestions(request) } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(20)
            Divider().opacity(0.5)
            ScrollView { Text(markdown(question.detail ?? "")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.frame(maxHeight: 340)
            HStack {
                Spacer()
                if let decline = question.options.first(where: { $0.label != question.intent?.approve }) { Button(decline.label) { answer(decline.label) }.buttonStyle(.bordered) }
                if let approve = question.options.first(where: { $0.label == question.intent?.approve }) { Button(approve.label) { answer(approve.label) }.buttonStyle(.borderedProminent) }
            }.padding(16)
        }.frame(maxWidth: 748).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.12)))
    }
    private func answer(_ label: String) { model.answerQuestions(request, answers: [["id": question.id, "selected": [label]]]) }
    private func markdown(_ value: String) -> AttributedString { (try? AttributedString(markdown: value)) ?? AttributedString(value) }
}
