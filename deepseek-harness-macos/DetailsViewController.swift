import AppKit

final class DetailsViewController: NSViewController {
    var onClose: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "详情")
    private let kindLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()

    override func loadView() {
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let close = NSButton.symbol("xmark", accessibility: "关闭详情")
        close.target = self; close.action = #selector(closePanel)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let header = NSStackView(views: [titleLabel, NSView(), close])
        header.orientation = .horizontal; header.alignment = .centerY

        kindLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        kindLabel.textColor = Theme.blue
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let empty = NSTextField(wrappingLabelWithString: "点击消息流中的工具行，查看它的详细信息")
        empty.textColor = .tertiaryLabelColor; empty.alignment = .center; empty.font = .systemFont(ofSize: 13)

        for child in [header, kindLabel, scroll, empty] { root.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28), header.heightAnchor.constraint(equalToConstant: 32),
            kindLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), kindLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), kindLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.topAnchor.constraint(equalTo: kindLabel.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor), empty.centerYAnchor.constraint(equalTo: root.centerYAnchor), empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -44),
        ])
        empty.identifier = NSUserInterfaceItemIdentifier("empty")
        view = root
    }

    func display(name: String, detail: String) {
        kindLabel.stringValue = name.uppercased()
        textView.string = detail
        view.subviews.first(where: { $0.identifier?.rawValue == "empty" })?.isHidden = true
    }

    @objc private func closePanel() { onClose?() }
}
