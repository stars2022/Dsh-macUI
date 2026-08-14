import AppKit

protocol ConversationViewControllerDelegate: AnyObject {
    func conversationDidSubmit(_ controller: ConversationViewController, text: String)
    func conversationDidRequestStop(_ controller: ConversationViewController)
    func conversation(_ controller: ConversationViewController, didSelectModel choice: ModelChoice)
    func conversation(_ controller: ConversationViewController, didSelectPermission permission: String)
    func conversation(_ controller: ConversationViewController, didSelectTool name: String, detail: String)
}

final class ConversationViewController: NSViewController, ComposerViewDelegate {
    weak var delegate: ConversationViewControllerDelegate?
    private let header = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "新会话")
    private let presetLabel = NSTextField(labelWithString: "标准模式")
    private let tabChat = NSButton(title: "聊天", target: nil, action: nil)
    private let tabTrajectory = NSButton(title: "轨迹", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let hero = NSStackView()
    private let composer = ComposerView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var session: SessionSummary?
    private var toolDetails: [Int: String] = [:]

    override func loadView() {
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        presetLabel.font = .systemFont(ofSize: 12)
        presetLabel.textColor = .secondaryLabelColor
        let log = NSButton(title: "会话日志", target: nil, action: nil)
        log.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        log.imagePosition = .imageLeading
        log.bezelStyle = .inline
        log.isBordered = false
        let headerRow = NSStackView(views: [titleLabel, NSView(), presetLabel, log])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10

        for button in [tabChat, tabTrajectory] {
            button.isBordered = false; button.bezelStyle = .inline; button.font = .systemFont(ofSize: 13, weight: .medium)
        }
        tabChat.contentTintColor = Theme.blue
        tabTrajectory.contentTintColor = .secondaryLabelColor
        let tabs = NSStackView(views: [tabChat, tabTrajectory, NSView()])
        tabs.orientation = .horizontal
        tabs.spacing = 30
        header.addSubview(headerRow); header.addSubview(tabs)
        headerRow.translatesAutoresizingMaskIntoConstraints = false; tabs.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22), headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -26), headerRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 20), headerRow.heightAnchor.constraint(equalToConstant: 30),
            tabs.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 30), tabs.trailingAnchor.constraint(equalTo: header.trailingAnchor), tabs.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 2), tabs.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -7),
        ])
        header.wantsLayer = true
        header.layer?.borderColor = Theme.separator.cgColor
        header.layer?.borderWidth = 0

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 30, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let fish = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: nil) ?? NSImage())
        fish.contentTintColor = .labelColor
        fish.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let headline = NSTextField(labelWithString: "Into the Unknown")
        headline.font = .systemFont(ofSize: 26, weight: .medium)
        let preview = NSTextField(labelWithString: "Preview")
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        preview.textColor = Theme.blue
        preview.rounded(9, fill: Theme.bubble)
        let heroHead = NSStackView(views: [fish, headline, preview])
        heroHead.orientation = .horizontal; heroHead.alignment = .centerY; heroHead.spacing = 10
        let heroHint = NSTextField(labelWithString: "选择工作区，然后描述你想构建的内容")
        heroHint.textColor = .secondaryLabelColor
        heroHint.font = .systemFont(ofSize: 13)
        hero.orientation = .vertical; hero.alignment = .centerX; hero.spacing = 12
        hero.addArrangedSubview(heroHead); hero.addArrangedSubview(heroHint)

        composer.delegate = self
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.alignment = .right

        for child in [header, scroll, composer, statusLabel] { root.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 82),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -14),
            composer.centerXAnchor.constraint(equalTo: root.centerXAnchor), composer.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.78), composer.widthAnchor.constraint(lessThanOrEqualToConstant: 780), composer.widthAnchor.constraint(greaterThanOrEqualToConstant: 520), composer.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -3),
            statusLabel.leadingAnchor.constraint(equalTo: composer.leadingAnchor), statusLabel.trailingAnchor.constraint(equalTo: composer.trailingAnchor), statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10), statusLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        view = root
        showHero()
    }

    func display(session: SessionSummary, items: [ConversationItem], models: [ModelChoice], currentModel: String?) {
        self.session = session
        titleLabel.stringValue = session.displayTitle
        presetLabel.stringValue = Self.displayPreset(session.preset)
        composer.configure(models: models, currentKey: currentModel, permission: session.permission)
        composer.setRunning(session.running)
        header.isHidden = session.blank && items.isEmpty
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if items.isEmpty { showHero() }
        else {
            for item in items { stack.addArrangedSubview(view(for: item)) }
            DispatchQueue.main.async { [weak self] in self?.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, (self?.stack.frame.height ?? 0) - (self?.scroll.contentView.bounds.height ?? 0)))) }
        }
        statusLabel.stringValue = session.running ? "智能体正在运行…" : ""
    }

    func setConnectionStatus(_ connected: Bool) { statusLabel.stringValue = connected ? (session?.running == true ? "智能体正在运行…" : "") : "正在重新连接…" }
    func focusComposer() { composer.focus() }

    private func showHero() {
        if hero.superview == nil { stack.addArrangedSubview(hero) }
        hero.topAnchor.constraint(greaterThanOrEqualTo: stack.topAnchor, constant: 125).isActive = true
    }

    private func view(for item: ConversationItem) -> NSView {
        let wrapper = FlippedView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.78).isActive = true
        wrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 748).isActive = true
        switch item {
        case let .user(text, time):
            let bubble = FlippedView()
            let label = messageText(text, font: .systemFont(ofSize: 16), color: .labelColor)
            bubble.rounded(22, fill: Theme.bubble)
            bubble.addSubview(label); label.pinEdges(to: bubble, insets: NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
            wrapper.addSubview(bubble); bubble.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([bubble.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor), bubble.topAnchor.constraint(equalTo: wrapper.topAnchor), bubble.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor), bubble.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, multiplier: 0.82)])
            bubble.toolTip = time.map(DateFormatter.localizedString) ?? ""
        case let .assistant(text, time):
            let label = markdownText(text)
            wrapper.addSubview(label); label.pinEdges(to: wrapper)
            label.toolTip = time.map(DateFormatter.localizedString) ?? ""
        case let .reasoning(text):
            let box = messageText("思考  \(text)", font: .systemFont(ofSize: 13.5), color: .secondaryLabelColor)
            box.rounded(10, fill: Theme.subtleFill)
            wrapper.addSubview(box); box.pinEdges(to: wrapper)
        case let .tool(name, summary, detail):
            let button = NSButton(title: "\(name.capitalized)   \(summary)", target: self, action: #selector(showTool(_:)))
            button.tag = toolDetails.count + 1
            toolDetails[button.tag] = detail
            button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.alignment = .left; button.isBordered = false; button.font = .systemFont(ofSize: 13.5, weight: .medium)
            button.rounded(9, fill: Theme.subtleFill)
            wrapper.addSubview(button); button.pinEdges(to: wrapper); button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        case let .notice(text):
            let label = messageText(text, font: .systemFont(ofSize: 13), color: .systemRed)
            wrapper.addSubview(label); label.pinEdges(to: wrapper)
        }
        return wrapper
    }

    private func messageText(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = font; label.textColor = color; label.isSelectable = true; label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.wantsLayer = true
        label.layer?.masksToBounds = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let cell = label.cell as? NSTextFieldCell { cell.lineBreakMode = .byWordWrapping }
        label.drawsBackground = false
        label.layer?.contents = nil
        return label
    }

    @objc private func showTool(_ sender: NSButton) {
        delegate?.conversation(self, didSelectTool: sender.title.components(separatedBy: "   ").first ?? "工具", detail: toolDetails[sender.tag] ?? "")
    }

    func composerDidSubmit(_ composer: ComposerView, text: String) { delegate?.conversationDidSubmit(self, text: text) }
    func composerDidRequestStop(_ composer: ComposerView) { delegate?.conversationDidRequestStop(self) }
    func composerDidSelectModel(_ composer: ComposerView, choice: ModelChoice) { delegate?.conversation(self, didSelectModel: choice) }
    func composerDidSelectPermission(_ composer: ComposerView, permission: String) { delegate?.conversation(self, didSelectPermission: permission) }

    private func markdownText(_ string: String) -> NSTextField {
        let label = messageText(string, font: .systemFont(ofSize: 16), color: .labelColor)
        if let attributed = try? AttributedString(markdown: string, options: .init(interpretedSyntax: .full)) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: mutable.length))
            label.attributedStringValue = mutable
        }
        return label
    }

    private static func displayPreset(_ value: String?) -> String { value == "code" ? "代码模式" : value == "minimal" ? "极简模式" : "标准模式" }
}

private extension DateFormatter {
    static func localizedString(_ date: Date) -> String {
        localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
}
