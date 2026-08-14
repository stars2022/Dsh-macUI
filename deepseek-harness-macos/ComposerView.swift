import AppKit

protocol ComposerViewDelegate: AnyObject {
    func composerDidSubmit(_ composer: ComposerView, text: String)
    func composerDidRequestStop(_ composer: ComposerView)
    func composerDidSelectModel(_ composer: ComposerView, choice: ModelChoice)
    func composerDidSelectPermission(_ composer: ComposerView, permission: String)
}

final class ComposerView: NSView, NSTextViewDelegate {
    weak var delegate: ComposerViewDelegate?
    private let scroll = NSScrollView()
    private let textView = ComposerTextView()
    private let permissionButton = NSButton()
    private let modelButton = NSButton()
    private let sendButton = NSButton.symbol("arrow.up", accessibility: "发送消息", pointSize: 14)
    private var choices: [ModelChoice] = []
    private var selectedModelKey: String?
    private(set) var running = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rounded(22, fill: Theme.input, border: Theme.separator)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.07
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.shadowRadius = 7

        textView.delegate = self
        textView.font = .systemFont(ofSize: 16)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.placeholder = "给智能体发送消息"
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        permissionButton.title = "Workspace Write"
        permissionButton.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil)
        permissionButton.imagePosition = .imageLeading
        permissionButton.bezelStyle = .inline
        permissionButton.isBordered = false
        permissionButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        permissionButton.target = self
        permissionButton.action = #selector(showPermissionMenu)

        modelButton.title = "选择模型"
        modelButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        modelButton.imagePosition = .imageTrailing
        modelButton.bezelStyle = .inline
        modelButton.isBordered = false
        modelButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        modelButton.target = self
        modelButton.action = #selector(showModelMenu)

        let command = NSButton.symbol("slash.circle", accessibility: "命令")
        let spacer = NSView()
        let toolbar = NSStackView(views: [command, permissionButton, spacer, modelButton, sendButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.rounded(16, fill: .labelColor)
        sendButton.contentTintColor = .windowBackgroundColor
        sendButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        addSubview(scroll)
        addSubview(toolbar)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 52), scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 180),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), toolbar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6), toolbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10), toolbar.heightAnchor.constraint(equalToConstant: 32),
        ])
        textView.submitHandler = { [weak self] in self?.send() }
        updateSendState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(models: [ModelChoice], currentKey: String?, permission: String?) {
        choices = models
        selectedModelKey = currentKey
        if let choice = models.first(where: { $0.key == currentKey }) { modelButton.title = choice.name }
        else if let currentKey { modelButton.title = currentKey.split(separator: "/").last.map(String.init) ?? currentKey }
        permissionButton.title = Self.displayPermission(permission ?? "workspace-write")
    }

    func setRunning(_ value: Bool) {
        running = value
        sendButton.image = NSImage(systemSymbolName: value ? "stop.fill" : "arrow.up", accessibilityDescription: value ? "停止" : "发送消息")
        sendButton.toolTip = value ? "停止" : "发送消息"
        updateSendState()
    }

    func focus() { window?.makeFirstResponder(textView) }

    func textDidChange(_ notification: Notification) { updateSendState() }

    @objc private func send() {
        if running { delegate?.composerDidRequestStop(self); return }
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        delegate?.composerDidSubmit(self, text: text)
        textView.string = ""
        updateSendState()
    }

    @objc private func showModelMenu() {
        let menu = NSMenu()
        var lastProvider: String?
        for choice in choices {
            if lastProvider != nil, lastProvider != choice.provider { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.name, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.representedObject = choice.key
            item.state = choice.key == selectedModelKey ? .on : .off
            item.toolTip = choice.description
            item.target = self
            menu.addItem(item)
            lastProvider = choice.provider
        }
        if choices.isEmpty { let item = NSMenuItem(title: "暂无可用模型", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.height + 4), in: modelButton)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let choice = choices.first(where: { $0.key == key }) else { return }
        selectedModelKey = key
        modelButton.title = choice.name
        delegate?.composerDidSelectModel(self, choice: choice)
    }

    @objc private func showPermissionMenu() {
        let values = [("read-only", "Read Only"), ("workspace-write", "Workspace Write"), ("danger-full-access", "Full access")]
        let menu = NSMenu()
        for value in values {
            let item = NSMenuItem(title: value.1, action: #selector(selectPermission(_:)), keyEquivalent: "")
            item.representedObject = value.0
            item.state = permissionButton.title == value.1 ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: permissionButton.bounds.height + 4), in: permissionButton)
    }

    @objc private func selectPermission(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value == "danger-full-access" {
            let alert = NSAlert()
            alert.messageText = "确认启用 Full access？"
            alert.informativeText = "智能体将减少确认步骤，并可直接执行更多操作，包括敏感操作、文件修改或外部命令。仅建议在你信任当前任务时使用。"
            alert.addButton(withTitle: "启用 Full access")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        permissionButton.title = Self.displayPermission(value)
        delegate?.composerDidSelectPermission(self, permission: value)
    }

    private func updateSendState() {
        sendButton.isEnabled = running || !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.alphaValue = sendButton.isEnabled ? 1 : 0.35
    }

    private static func displayPermission(_ value: String) -> String {
        switch value { case "read-only": return "Read Only"; case "danger-full-access": return "Full access"; default: return "Workspace Write" }
    }
}

final class ComposerTextView: NSTextView {
    var submitHandler: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) { submitHandler?(); return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.placeholderTextColor]
            placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
        }
    }
}
