import Foundation

@main
enum ConversationChromeValidation {
    static func main() {
        validateStableToolTitles()
        validateMessageClocks()
        validateTurnTailAndUserStack()
        validateCommandLifecycleAndTurnMetrics()
        validateStreamingMarkdownState()
        validateConciseConversationRows()
        validateFileEditDiffProjection()
        validatePluginInventoryEnvelope()
        validateForkPayload()
        validateSessionStatsProjection()
        validateWebUISurfaceContracts()
        print("ConversationChromeValidation: tool lifecycle, concise transcript, command row, turn metrics, 3 clocks and transcript/stream/menu/stats fixtures passed")
    }

    private static func validateStableToolTitles() {
        for state in [ToolState.running, .ok, .error, .stopped] {
            let tool = ToolCall(id: "call-\(state.rawValue)", name: "bash", arguments: "{}",
                                title: "Bash", summary: "pwd", rawInput: nil,
                                output: state == .error ? "failed" : nil, variant: .bash,
                                state: state, errorCode: nil, summarySuffix: nil,
                                card: nil, filePath: nil, presentation: nil,
                                cordis: nil, subCalls: [])
            precondition(tool.displayTitle == "Bash", "tool title drifted for \(state.rawValue)")
        }
    }

    private static func validateMessageClocks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 18))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 6, minute: 5))!
        let sameYear = calendar.date(from: DateComponents(year: 2026, month: 2, day: 3, hour: 4, minute: 9))!
        let priorYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23, minute: 7))!
        precondition(messageClock(today, now: now, calendar: calendar) == "06:05")
        precondition(messageClock(sameYear, now: now, calendar: calendar) == "2月3日 04:09")
        precondition(messageClock(priorYear, now: now, calendar: calendar) == "2025年12月31日 23:07")
    }

    private static func validateTurnTailAndUserStack() {
        let userContent: [[String: Any]] = [
            ["type": "image", "attachment": [
                "attachmentId": "image-1", "mediaType": "image/png", "bytes": 12,
                "width": 20, "height": 10,
            ]],
            ["type": "text", "text": "看这张图"],
        ]
        let assistantContent: [[String: Any]] = [
            ["type": "text", "text": "第一段"],
            ["type": "reasoning", "text": "思考"],
            ["type": "text", "text": "第二段"],
        ]
        let events: [[String: Any]] = [
            event("user/message", seq: 1, data: [
                "turn": 1, "source": ["kind": "user"], "message": ["content": userContent],
            ]),
            event("assistant/message", seq: 2, data: [
                "turn": 1, "step": 1,
                "message": ["id": "message-1", "content": assistantContent],
            ]),
            event("turn/end", seq: 3, data: ["turn": 1, "reason": ["kind": "completed"]]),
        ]
        let items = HarnessAPI.parseHistory(events)
        let userItems = items.filter { if case .user = $0.kind { return true }; return false }
        precondition(userItems.count == 1)
        if case let .user(text, images) = userItems[0].kind {
            precondition(text == "看这张图" && images.count == 1)
        } else { preconditionFailure("user image/text stack was split") }

        let textBlocks = items.compactMap { item -> String? in
            if case let .assistant(text, streaming) = item.kind {
                precondition(streaming == false)
                return text
            }
            return nil
        }
        precondition(textBlocks == ["第一段", "第二段"])
        let tails = items.compactMap { item -> (String, String?)? in
            if case let .assistantActions(text, messageId) = item.kind { return (text, messageId) }
            return nil
        }
        precondition(tails.count == 1)
        precondition(tails[0].0 == "第一段第二段" && tails[0].1 == "message-1")

        let openTurn = HarnessAPI.parseHistory(Array(events.dropLast()))
        precondition(!openTurn.contains { if case .assistantActions = $0.kind { return true }; return false })
    }

    private static func validateStreamingMarkdownState() {
        var accumulator = StreamingAssistantAccumulator(turn: 2, step: 3)
        precondition(accumulator.push(chunk: ["type": "block-start", "index": 0, "blockType": "text"], seq: 10, time: nil))
        precondition(accumulator.push(chunk: ["type": "text-delta", "index": 0, "text": "```swift\nlet x = 1"], seq: 11, time: nil))
        let live = accumulator.items(running: true)
        guard live.count == 1, case let .assistant(text, streaming) = live[0].kind else {
            preconditionFailure("streaming assistant item missing")
        }
        precondition(streaming && text.hasPrefix("```swift"))
        let settled = accumulator.items(running: false)
        guard settled.count == 1, case let .assistant(_, streaming) = settled[0].kind else {
            preconditionFailure("settled assistant item missing")
        }
        precondition(streaming == false)
    }

    private static func validateConciseConversationRows() {
        let read = tool(id: "read-1", variant: .read, state: .ok)
        let bash = tool(id: "bash-1", variant: .bash, state: .running)
        let items = [
            ConversationItem(id: "text", kind: .assistant(text: "外层正文", streaming: false), seq: 1, time: nil),
            ConversationItem(id: "thought-1", kind: .reasoning("不应显示的完整思考", running: false), seq: 2, time: nil),
            ConversationItem(id: "read", kind: .tool(read), seq: 3, time: nil),
            ConversationItem(id: "thought-2", kind: .reasoning("仍然不应显示", running: true), seq: 4, time: nil),
            ConversationItem(id: "bash", kind: .tool(bash), seq: 5, time: nil),
        ]
        let rows = conciseConversationRows(items)
        precondition(rows.count == 2, "concise transcript failed to merge adjacent private activity")
        guard case let .activities(group) = rows[1] else {
            preconditionFailure("concise transcript did not emit an activity disclosure")
        }
        precondition(group.tools.map(\.id) == ["read-1", "bash-1"])
        precondition(group.running && group.reasoningRunning)
        precondition(group.summary == "正在运行命令")

        let completedThoughtOnly = conciseConversationRows([
            ConversationItem(id: "before", kind: .assistant(text: "前", streaming: false), seq: 1, time: nil),
            ConversationItem(id: "private", kind: .reasoning("隐藏", running: false), seq: 2, time: nil),
            ConversationItem(id: "after", kind: .assistant(text: "后", streaming: false), seq: 3, time: nil),
        ])
        precondition(completedThoughtOnly.count == 2, "completed reasoning leaked into concise transcript")

        let activeThoughtOnly = conciseConversationRows([
            ConversationItem(id: "private-running", kind: .reasoning("隐藏", running: true), seq: 1, time: nil),
        ])
        guard activeThoughtOnly.count == 1, case let .activities(active) = activeThoughtOnly[0] else {
            preconditionFailure("active reasoning lost its generic progress row")
        }
        precondition(active.tools.isEmpty && active.running)
        precondition(active.summary == "正在思考")

        let edit = tool(id: "edit-1", variant: .edit, state: .ok)
        let code = ToolCall(id: "code-1", name: "code", arguments: "{}",
                            title: "Code", summary: "Review import comment region", rawInput: nil,
                            output: "aggregate output that must not own the disclosure", variant: .code,
                            state: .ok, errorCode: nil, summarySuffix: nil, card: nil, filePath: nil,
                            presentation: nil, cordis: nil, subCalls: [read, edit])
        let codeGroup = CompactActivityGroup(id: "code-group", tools: [code], reasoningRunning: false)
        precondition(codeGroup.disclosureTools.map(\.id) == ["read-1", "edit-1"],
                     "Code container leaked instead of exposing its result-owning subcalls")
        precondition(codeGroup.summary == "读取了文件编辑了文件")

        let runningCode = ToolCall(id: "code-running", name: "code", arguments: "{}",
                                   title: "Code", summary: "Inspect settings contract", rawInput: nil,
                                   output: nil, variant: .code, state: .running, errorCode: nil,
                                   summarySuffix: nil, card: nil, filePath: nil, presentation: nil,
                                   cordis: nil, subCalls: [read])
        let runningCodeGroup = CompactActivityGroup(id: "code-running-group", tools: [runningCode], reasoningRunning: true)
        precondition(runningCodeGroup.summary == "Inspect settings contract",
                     "running Code summary stopped acting as the transient title")

        let codeDispatchEvents: [[String: Any]] = [
            event("assistant/message", seq: 20, data: [
                "turn": 2, "step": 1,
                "message": ["content": [[
                    "type": "tool-call", "id": "code-root", "name": "run_code",
                    "arguments": #"{"description":"Run checks","code":"await bash({ command: 'echo OK' })"}"#,
                ]]],
            ]),
            event("tool/code-dispatch-start", seq: 21, data: [
                "turn": 2, "step": 1, "rootCallId": "code-root", "parentCallId": "code-root",
                "subCallId": "code-root:code:1", "name": "bash",
                "arguments": ["command": "echo OK", "description": "Print OK"],
            ]),
            event("tool/code-dispatch", seq: 22, data: [
                "turn": 2, "step": 1, "rootCallId": "code-root", "parentCallId": "code-root",
                "subCallId": "code-root:code:1", "name": "bash",
                "arguments": ["command": "echo OK", "description": "Print OK"],
                "isError": false, "content": [["type": "text", "text": "OK\n"]],
            ]),
            event("tool/result", seq: 23, data: [
                "turn": 2, "step": 1, "callId": "code-root", "isError": false,
                "content": [["type": "text", "text": "aggregate Code output"]],
            ]),
        ]
        let parsedCodeRows = conciseConversationRows(HarnessAPI.parseHistory(codeDispatchEvents))
        guard parsedCodeRows.count == 1, case let .activities(parsedCodeGroup) = parsedCodeRows[0] else {
            preconditionFailure("parsed Code dispatch did not become one concise activity group")
        }
        precondition(parsedCodeGroup.disclosureTools.count == 1,
                     "synthetic Code row leaked into the concise disclosure")
        let dispatchedCommand = parsedCodeGroup.disclosureTools[0]
        precondition(dispatchedCommand.id == "code-root:code:1" && dispatchedCommand.variant == .bash)
        precondition(dispatchedCommand.output == "OK\n",
                     "Code aggregate output replaced the child command's own output")
        precondition(dispatchedCommand.inputText?.contains("echo OK") == true && dispatchedCommand.expandable,
                     "Code-dispatched command no longer keeps its command and output in one expandable row")
    }

    private static func validatePluginInventoryEnvelope() {
        let entries: [[String: Any]] = [[
            "entryId": "include:plugin-inventory",
            "moduleName": "@deepseek-ai/dsh-host-plugin-inventory",
            "enabled": true,
            "fiberPhase": "active",
        ]]
        for payload in [["entries": entries], ["value": ["entries": entries]]] {
            guard case let .success(rows) = HarnessAPI.parsePluginInventorySnapshot(payload) else {
                preconditionFailure("valid plugin inventory envelope was rejected")
            }
            precondition(rows.count == 1 && rows[0].entryId == "include:plugin-inventory" && rows[0].enabled)
        }
    }

    private static func validateFileEditDiffProjection() {
        let callView: [String: Any] = [
            "card": "diff", "title": "Edit Sources/App.swift",
            "diffs": [["path": "Sources/App.swift", "oldText": "old one\nold two", "newText": "new one\nnew two"]],
            "locations": [["path": "Sources/App.swift"]],
        ]
        let resultView: [String: Any] = [
            "card": "diff", "title": "Edit Sources/App.swift",
            "diffs": [["path": "Sources/App.swift", "oldText": "old one\nold two", "newText": "new one\nnew two"]],
        ]
        let entries: [[String: Any]] = [
            ["event": event("tool/call", seq: 10, data: [
                "turn": 1, "step": 1, "callId": "edit-1", "name": "edit",
                "arguments": #"{"file_path":"Sources/App.swift","old_string":"old","new_string":"new"}"#,
            ]), "view": ["view": callView]],
            event("assistant/message", seq: 11, data: [
                "turn": 1, "step": 1, "message": ["content": [[
                    "type": "tool-call", "id": "edit-1", "name": "edit",
                    "arguments": #"{"file_path":"Sources/App.swift","old_string":"old","new_string":"new"}"#,
                ]]],
            ]),
            ["event": event("tool/result", seq: 12, data: [
                "turn": 1, "step": 1, "callId": "edit-1", "isError": false,
                "content": [["type": "text", "text": "ok"]],
            ]), "view": ["view": resultView]],
        ]
        let tools = HarnessAPI.parseHistory(entries).compactMap { item -> ToolCall? in
            if case let .tool(tool) = item.kind { return tool }
            return nil
        }
        guard tools.count == 1, case let .diff(card)? = tools[0].presentation else {
            preconditionFailure("edit result did not project a diff presentation")
        }
        precondition(tools[0].filePath == "Sources/App.swift")
        precondition(card.additions == 2 && card.deletions == 2 && card.fileCount == 1)
        precondition(tools[0].summarySuffix == "+2 -2", "collapsed edit row lost Codex-style change counts")
    }

    private static func validateCommandLifecycleAndTurnMetrics() {
        let base = 1_786_665_600_000.0
        let events: [[String: Any]] = [
            ["type": "command/run", "seq": 1, "time": base,
             "data": ["commandId": "permission-1", "name": "permission", "args": "read-only"]],
            ["type": "command/done", "seq": 2, "time": base + 10,
             "data": ["commandId": "permission-1", "kind": "success", "text": "preset read-only"]],
            ["type": "turn/start", "seq": 3, "time": base + 100, "data": ["turn": 7]],
            ["type": "step/start", "seq": 4, "time": base + 200, "data": ["turn": 7, "step": 1]],
            ["type": "assistant/chunk", "seq": 5, "time": base + 2_200,
             "data": ["turn": 7, "step": 1, "chunk": ["type": "text-delta", "index": 0, "text": "完成"]]],
            ["type": "assistant/message", "seq": 6, "time": base + 3_200,
             "data": ["turn": 7, "step": 1, "usage": ["outputTokens": 103],
                      "message": ["id": "metric-message", "content": [["type": "text", "text": "完成"]]]]],
            ["type": "turn/end", "seq": 7, "time": base + 3_600, "data": ["turn": 7]],
        ]
        let items = HarnessAPI.parseHistory(events)
        let commandRows = items.compactMap { item -> (String, String, Bool)? in
            if case let .command(name, summary, _, running, _) = item.kind { return (name, summary, running) }
            return nil
        }
        precondition(commandRows.count == 1)
        precondition(commandRows[0].0 == "permission" && commandRows[0].1 == "preset read-only" && !commandRows[0].2)
        let metrics = items.first { if case .assistantActions = $0.kind { return true }; return false }?.metrics
        precondition(metrics?.runMs == 3_500)
        precondition(metrics?.ttftMs == 2_000)
        precondition(metrics?.tokensPerSecond == 103)
    }

    private static func validateForkPayload() {
        let wholeSession = HarnessAPI.forkPayload(sessionId: "session-1", atSeq: nil)
        precondition(wholeSession["sessionId"] as? String == "session-1")
        precondition(wholeSession["atSeq"] == nil, "sidebar fork must let the Host choose the completed-turn cut")

        let messageTail = HarnessAPI.forkPayload(sessionId: "session-1", atSeq: 42)
        precondition(messageTail["atSeq"] as? Int == 42, "message-tail fork lost its explicit cut")
    }

    private static func validateSessionStatsProjection() {
        let stats = SessionStats(json: [
            "turns": 1, "steps": 6, "llmMs": 16_600.0, "toolMs": 22_000.0,
            "ttftMs": 5_400.0, "ttftSteps": 6, "decodeMs": 11_607.0,
            "decodeTokens": 1_300,
        ])
        precondition(stats.turns == 1 && stats.steps == 6)
        precondition(stats.llmMs == 16_600 && stats.toolMs == 22_000)
        precondition(stats.ttftMs / Double(stats.ttftSteps) == 900)
        precondition(Int((Double(stats.decodeTokens) / (stats.decodeMs / 1_000)).rounded()) == 112)
        let usage = TokenUsage(json: [
            "uncachedInputTokens": 3_560, "cacheReadTokens": 14_440,
            "cacheWriteTokens": 1_000, "outputTokens": 1_300,
        ])
        let input = usage.uncachedInput + usage.cacheRead + usage.cacheWrite
        precondition(input == 19_000)
        precondition(Int((Double(usage.cacheRead) / Double(input) * 100).rounded()) == 76)
    }

    private static func validateWebUISurfaceContracts() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let native = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/RootView.swift"), encoding: .utf8)
        let icons = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/DeepSeekIcons.swift"), encoding: .utf8)
        let wordmark = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/DeepSeekBrandWordmark.swift"), encoding: .utf8)
        let material = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/NativeMaterialView.swift"), encoding: .utf8)
        let app = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/HarnessMacApp.swift"), encoding: .utf8)
        let appModel = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/AppModel.swift"), encoding: .utf8)
        let api = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/HarnessAPI.swift"), encoding: .utf8)
        let toolPresentation = try! String(contentsOf: root.appendingPathComponent("deepseek-harness-macos/ToolPresentationViews.swift"), encoding: .utf8)

        precondition(native.contains("Button(\"分叉会话\")"))
        precondition(native.contains("Button(\"归档会话\")"))
        precondition(!native.contains("分支到新会话"), "session menu wording drifted from WebUI")
        precondition(native.contains("private struct WorkspaceViewOptionsPopover")
                     && !native.contains("Picker(\"分组\""), "workspace grouping regressed to nested native submenus")
        precondition(native.contains("? \"取消标记\" : \"好的回答\""))
        precondition(native.contains("? \"取消标记\" : \"有问题的回答\""))
        precondition(native.contains("Button(\"Inspect\")"), "tool menu lost the WebUI Inspect action")
        precondition(native.contains("facts.append(\"用时 ") && native.contains("facts.append(\"首 token ")
                     && native.contains(" tok/s\")"), "assistant turn-tail metrics copy drifted from WebUI")
        precondition(native.contains("Spacer(minLength: 12)"), "assistant actions no longer leave metrics on the right")
        precondition(native.contains(".popover(isPresented: $presented, arrowEdge: .bottom)"), "context meter reverted to a menu")
        precondition(native.contains(".frame(width: 264)"), "context popover lost its WebUI width")
        precondition(native.contains("legend(\"系统提示词\"") && native.contains("legend(\"对话消息\""), "context breakdown labels drifted")
        precondition(native.contains("Text(\"可配置\").tag(\"可配置\")") && native.contains("Text(\"已安装\").tag(\"已安装\")"), "plugin settings tabs disappeared")
        precondition(native.contains("添加提供方") && native.contains("removeProvider"), "model provider add/remove controls disappeared")
        precondition(native.contains("settingsLine(\"简洁显示模式\"") && native.contains("conciseConversationRows(model.history)"), "concise display setting disappeared")
        precondition(appModel.contains("compactConversationDisplay") && appModel.contains("UserDefaults.standard.set(compactConversationDisplay"), "concise display setting stopped persisting")
        precondition(native.contains("打开配置文件") && native.contains("model.openSettingsDocument"), "settings document action disappeared")
        precondition(app.contains("Settings {") && native.contains("showSettingsWindow:"), "settings stopped using the native macOS Settings window")
        precondition(native.contains("Label(\"通用\", systemImage: \"gearshape\")")
                     && native.contains("Label(\"模型\", systemImage: \"cpu\")")
                     && native.contains("Label(\"插件\", systemImage: \"puzzlepiece.extension\")")
                     && native.contains("Label(\"Agent 预设\", systemImage: \"person.2\")"),
                     "native settings tabs lost their icons")
        precondition(api.contains("func settings(completion:") && api.contains("settings.openDocument"), "native settings stopped using the Host configuration contract")
        precondition(api.contains("parsePluginInventorySnapshot") && api.contains("value[\"value\"] as? [String: Any] ?? value"), "plugin inventory direct response compatibility regressed")
        precondition(native.contains("!model.draftImages.isEmpty") && native.contains("ComposerPrimaryButtonStyle"), "composer primary button lost image-only or single-opacity behavior")

        for repositoryGlyph in [".newChat", ".personalization", ".projectAdd", ".settings", ".folderOpen", ".folderClosed", ".ellipsis"] {
            precondition(native.contains(repositoryGlyph), "native chrome does not consume repository glyph \(repositoryGlyph)")
        }
        precondition(icons.contains("private static let newChat"))
        precondition(icons.contains("private static let personalization"))
        precondition(icons.contains("private static let projectAddPlus"))
        precondition(native.contains("searchExpanded ? 30 : 28"), "sidebar search lost the WebUI collapsed/expanded geometry")
        precondition(native.contains(".frame(height: 32)"), "session row lost its WebUI height")
        precondition(native.contains("HeroWorkspaceSeat()"), "blank-session Hero lost the workspace selector")
        precondition(native.contains("model.currentWorkspace?.name ?? \"选择工作区\""), "Hero selector stopped echoing the current workspace")
        precondition(native.contains("SessionStatsLine()"), "composer lost the durable stats strip")
        precondition(native.contains("NavigationSplitView(columnVisibility:"), "root stopped using the native macOS sidebar")
        precondition(native.contains(".navigationTitle(conversationTitle)")
                     && native.contains("ToolbarItem(placement: .principal)")
                     && native.contains("Text(conversationTitle)"), "native conversation title disappeared")
        precondition(material.contains("window.titleVisibility = .visible"), "AppKit is suppressing the native conversation title")
        precondition(native.contains("ToolbarItemGroup(placement: .navigation)"), "native back/forward toolbar controls disappeared")
        precondition(native.contains("tab(\"对话\", tag: 0)") && native.contains("tab(\"轨迹\", tag: 1)"), "conversation/trajectory switch disappeared")
        precondition(material.contains("NSTitlebarAccessoryViewController"), "trailing titlebar actions are no longer right-anchored")
        precondition(material.contains("controller.layoutAttribute = .right"), "Session log stopped anchoring to the right edge")
        precondition(material.contains("TitlebarSubagentCatalog")
                     && material.contains("TitlebarSubagentRow")
                     && material.contains("openChild(child, parent)"),
                     "subagent catalog stopped opening independent child conversations")
        precondition(native.contains("guard session.origin != \"subagent\""),
                     "subagent children leaked back into the ordinary sidebar")
        precondition(material.contains("Text(\"Session log\")") && material.contains("DeepSeekIcon(kind: .download"), "Session log stopped being a download control")
        precondition(material.contains("JobListMenu(jobs: jobs)") && native.contains("backgroundJobs: currentJobs"),
                     "background jobs disappeared from the session header")
        precondition(api.contains("api/session.export") && appModel.contains("NSSavePanel()"), "Session log export/download pipeline disappeared")
        precondition(api.contains("func executeCommand(sessionId:") && api.contains("call(\"commands/execute\""), "Host command execution pipeline disappeared")
        precondition(api.contains("executeCommand(sessionId: sessionId, line: \"/permission \\(permission)\""), "permission selection is being sent to the model instead of commands.execute")
        precondition(appModel.contains("commands.contains(where: { $0.name == name })"), "registered slash commands are no longer intercepted before session.prompt")
        precondition(appModel.contains("projections.plan?.targetActive == true") && appModel.contains("executeCommand(sessionId: sessionId, line: \"/plan off\")"), "Plan projection exit behavior drifted")
        precondition(native.contains("@State private var expandedSection: Section?") && native.contains("private func toggle(_ section: Section)"), "Model/Effort menu stopped expanding inline")
        precondition(material.contains("struct NativeConversationScrollObserver") && material.contains("distance <= 24.5"), "reader-owned bottom-follow tracking disappeared")
        precondition(native.contains("if !followsLatest") && native.contains("回到最新内容"), "back-to-bottom control disappeared")
        precondition(native.contains("if followsLatest { scrollToLatest(proxy) }"), "streaming output no longer respects paused follow")
        precondition(native.contains("actionContents.fixedSize(horizontal: true, vertical: false)"), "user message actions stopped aligning to the trailing bubble edge")
        precondition(native.contains("TabView(selection: $selection)")
                     && native.contains("Label(\"通用\", systemImage: \"gearshape\")")
                     && native.contains("settingsSection(\"新建会话\")")
                     && native.contains("ScrollView {"),
                     "settings stopped using native SwiftUI tabs and scrollable divided sections")
        precondition(native.contains("ComposerTextInput(text: $draft")
                     && native.contains("scrollView.hasVerticalScroller = required > parent.maximumHeight"),
                     "composer lost its native capped scrolling editor")
        precondition(native.contains("Label(\"添加工作区…\", systemImage: \"plus\")")
                     && native.contains("panel.canCreateDirectories = true"),
                     "blank-session workspace picker lost Add Workspace")
        precondition(native.contains("private struct GoalCommandInputRow"), "Goal command input projection disappeared")
        precondition(native.contains("private struct HarnessSidebarBrandBar"), "brand stopped belonging to the collapsible sidebar")
        precondition(native.contains("DeepSeekIcon(kind: .chevronLeft") && native.contains("DeepSeekIcon(kind: .chevronRight"), "session back/forward repository glyphs disappeared")
        precondition(native.contains("navigationIDs.removeSubrange"), "normal session selection stopped truncating forward history")
        precondition(native.contains("!model.archivedSessionIds.contains(id)"), "history navigation stopped skipping archived sessions")
        precondition(wordmark.contains("private static let inkPaths") && wordmark.contains("private static let badgePaths"), "titlebar wordmark is no longer repository-vector native")
        precondition(material.contains("Theme.sidebar.cgColor"), "sidebar stopped using the system sidebar color token")
        precondition(!material.contains("struct NativeGlassSidebar"), "whole-sidebar Liquid Glass returned")
        precondition(native.contains("private final class ComposerNativeTextView")
                     && native.contains("guard !textView.hasMarkedText() else { return false }")
                     && native.contains("hasPendingNativeChange"), "composer lost its marked-text-safe AppKit synchronization")
        precondition(toolPresentation.contains("rowBackground(row)")
                     && toolPresentation.contains("Theme.stateSuccess")
                     && toolPresentation.contains("Theme.stateError"), "file edit diff lost red/green change rendering")
    }

    private static func event(_ type: String, seq: Int, data: [String: Any]) -> [String: Any] {
        ["type": type, "seq": seq, "time": 1_786_665_600_000.0 + Double(seq), "data": data]
    }

    private static func tool(id: String, variant: ToolVariant, state: ToolState) -> ToolCall {
        let name: String = { switch variant { case .bash: return "bash"; case .edit: return "edit"; default: return "read" } }()
        let title: String = { switch variant { case .bash: return "Bash"; case .edit: return "Edit"; default: return "Read" } }()
        return ToolCall(id: id, name: name, arguments: "{}",
                 title: title, summary: id, rawInput: nil,
                 output: state == .running ? nil : "ok", variant: variant, state: state,
                 errorCode: nil, summarySuffix: nil, card: nil, filePath: nil,
                 presentation: nil, cordis: nil, subCalls: [])
    }
}
