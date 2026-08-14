import AppKit

final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let serverField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    var onServerChanged: (() -> Void)?

    convenience init() {
        let content = NSViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.contentViewController = content
        window.center()
        self.init(window: window)
        content.view = buildView()
    }

    private func buildView() -> NSView {
        let root = FlippedView()
        let sidebar = FlippedView()
        sidebar.wantsLayer = true; sidebar.layer?.backgroundColor = Theme.sidebar.cgColor
        let heading = NSTextField(labelWithString: "设置")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let general = settingsRow("通用设置", symbol: "gearshape.fill", selected: true)
        let model = settingsRow("模型", symbol: "cpu", selected: false)
        let plugins = settingsRow("插件", symbol: "puzzlepiece.extension", selected: false)
        let presets = settingsRow("Agent 预设", symbol: "person.2", selected: false)
        let nav = NSStackView(views: [heading, general, model, plugins, presets, NSView()])
        nav.orientation = .vertical; nav.alignment = .leading; nav.spacing = 8
        sidebar.addSubview(nav); nav.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "通用设置")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let close = NSButton.symbol("xmark", accessibility: "关闭")
        close.target = self; close.action = #selector(closeWindow)
        let titleRow = NSStackView(views: [title, NSView(), close]); titleRow.orientation = .horizontal; titleRow.alignment = .centerY

        let serverTitle = NSTextField(labelWithString: "服务器")
        serverTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let serverHint = NSTextField(labelWithString: "原生客户端连接的 DeepSeek Harness 地址")
        serverHint.textColor = .secondaryLabelColor; serverHint.font = .systemFont(ofSize: 12)
        serverField.stringValue = HarnessAPI.shared.baseURL.absoluteString
        serverField.placeholderString = "http://localhost:3080"
        serverField.delegate = self
        serverField.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let appearanceTitle = NSTextField(labelWithString: "外观")
        appearanceTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let appearance = NSSegmentedControl(labels: ["浅色", "深色", "跟随系统"], trackingMode: .selectOne, target: self, action: #selector(changeAppearance(_:)))
        appearance.selectedSegment = UserDefaults.standard.integer(forKey: "appearance")

        let languageTitle = NSTextField(labelWithString: "语言")
        languageTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let language = NSPopUpButton(); language.addItems(withTitles: ["中文", "English"]); language.selectItem(at: 0)

        let body = NSStackView(views: [titleRow, serverTitle, serverHint, serverField, statusLabel, separator(), appearanceTitle, appearance, separator(), languageTitle, language, NSView()])
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        root.addSubview(sidebar); root.addSubview(body)
        sidebar.translatesAutoresizingMaskIntoConstraints = false; body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 210),
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18), nav.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18), nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24), nav.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            body.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 32), body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28), body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24), body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            titleRow.widthAnchor.constraint(equalTo: body.widthAnchor), serverField.widthAnchor.constraint(equalTo: body.widthAnchor), appearance.widthAnchor.constraint(equalToConstant: 280),
        ])
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .systemRed
        return root
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let url = URL(string: serverField.stringValue), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            statusLabel.stringValue = "请输入有效的 HTTP 或 HTTPS 地址"
            return
        }
        statusLabel.stringValue = ""
        HarnessAPI.shared.baseURL = url
        onServerChanged?()
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment, forKey: "appearance")
        switch sender.selectedSegment { case 0: NSApp.appearance = NSAppearance(named: .aqua); case 1: NSApp.appearance = NSAppearance(named: .darkAqua); default: NSApp.appearance = nil }
    }
    @objc private func closeWindow() { close() }

    private func settingsRow(_ title: String, symbol: String, selected: Bool) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.imagePosition = .imageLeading; button.alignment = .left; button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: selected ? .medium : .regular); button.rounded(9, fill: selected ? Theme.subtleFill : .clear)
        button.widthAnchor.constraint(equalToConstant: 174).isActive = true; button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }
    private func separator() -> NSView { let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = Theme.separator.cgColor; view.heightAnchor.constraint(equalToConstant: 1).isActive = true; view.widthAnchor.constraint(equalToConstant: 490).isActive = true; return view }
}
