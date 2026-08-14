import AppKit

enum Theme {
    static let blue = NSColor(srgbRed: 65 / 255, green: 118 / 255, blue: 230 / 255, alpha: 1)
    /// `--dsw-alias-state-business-primary`: DeepSeek 500 in light mode and
    /// DeepSeek 400 in dark mode, copied from WebUI's design-platform.css.
    static let business = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 103 / 255, green: 158 / 255, blue: 254 / 255, alpha: 1)
            : blue
    }
    /// Exact WebUI lifecycle tokens (`StateDot.module.css`).
    static let stateOngoing = NSColor(srgbRed: 86 / 255, green: 134 / 255, blue: 254 / 255, alpha: 1)
    static let stateSuccess = NSColor(srgbRed: 34 / 255, green: 197 / 255, blue: 94 / 255, alpha: 1)
    static let stateWarning = NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 1)
    static let warnLabel = NSColor(srgbRed: 221 / 255, green: 134 / 255, blue: 41 / 255, alpha: 1)
    static let warnTertiary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 39 / 255, green: 36 / 255, blue: 31 / 255, alpha: 1)
            : NSColor(srgbRed: 254 / 255, green: 245 / 255, blue: 231 / 255, alpha: 1)
    }
    static let tip = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 53 / 255, green: 54 / 255, blue: 56 / 255, alpha: 1)
            : NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 247 / 255, alpha: 1)
    }
    static let borderL1 = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    }
    static let stateError = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 242 / 255, green: 90 / 255, blue: 90 / 255, alpha: 1)
            : NSColor(srgbRed: 236 / 255, green: 19 / 255, blue: 19 / 255, alpha: 1)
    }
    static let bubble = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 52 / 255, green: 65 / 255, blue: 91 / 255, alpha: 1)
            : NSColor(srgbRed: 237 / 255, green: 243 / 255, blue: 254 / 255, alpha: 1)
    }
    static let sidebar = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 27 / 255, green: 27 / 255, blue: 28 / 255, alpha: 1)
            : NSColor(srgbRed: 249 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)
    }
    static let subtleFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(srgbRed: 241 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1)
    }
    static let input = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : .white
    }
    static let separator = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.08)
    }
    /// Markdown surfaces copied from the WebUI's code-block aliases.
    static let markdownCodeBanner = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(srgbRed: 249 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)
    }
    static let markdownCode = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 27 / 255, green: 27 / 255, blue: 28 / 255, alpha: 1)
            : NSColor(srgbRed: 249 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1)
    }
    static let markdownInlineCode = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(srgbRed: 235 / 255, green: 238 / 255, blue: 242 / 255, alpha: 1)
    }
    static let selector = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 53 / 255, green: 54 / 255, blue: 56 / 255, alpha: 1)
            : NSColor(srgbRed: 245 / 255, green: 246 / 255, blue: 247 / 255, alpha: 1)
    }
}

extension NSView {
    func pinEdges(to view: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: view.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func rounded(_ radius: CGFloat, fill: NSColor? = nil, border: NSColor? = nil, borderWidth: CGFloat = 1) {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = fill?.cgColor
        layer?.borderColor = border?.cgColor
        layer?.borderWidth = border == nil ? 0 : borderWidth
    }
}

extension NSButton {
    static func symbol(_ name: String, accessibility: String, pointSize: CGFloat = 15) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = accessibility
        button.setAccessibilityLabel(accessibility)
        return button
    }
}

extension NSEdgeInsets {
    init(all: CGFloat) { self.init(top: all, left: all, bottom: all, right: all) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    var hoverColor = Theme.subtleFill

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = hoverColor.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

final class PaddedTextField: NSTextField {
    var textInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        super.textShouldBeginEditing(textObject)
    }
}
