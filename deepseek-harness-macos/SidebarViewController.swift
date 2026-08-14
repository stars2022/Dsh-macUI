import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidRequestNewSession(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, didSelect session: SessionSummary)
    func sidebarDidRequestSettings(_ sidebar: SidebarViewController)
    func sidebar(_ sidebar: SidebarViewController, didRequestRename session: SessionSummary)
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var delegate: SidebarViewControllerDelegate?
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "暂无会话")
    private var allSessions: [SessionSummary] = []
    private var filtered: [SessionSummary] = []
    private var currentId: String?

    override func loadView() {
        let root = FlippedView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.sidebar.cgColor

        let brand = NSTextField(labelWithString: "DeepSeek")
        brand.font = .systemFont(ofSize: 20, weight: .semibold)
        let fish = NSImageView(image: NSImage(systemSymbolName: "fish.fill", accessibilityDescription: "DeepSeek") ?? NSImage())
        fish.contentTintColor = .labelColor
        let collapse = NSButton.symbol("sidebar.left", accessibility: "收起侧边栏")
        let brandRow = NSStackView(views: [fish, brand, NSView(), collapse])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 8
        fish.widthAnchor.constraint(equalToConstant: 27).isActive = true

        let newButton = NSButton(title: "新建会话", target: self, action: #selector(newSession))
        newButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        newButton.imagePosition = .imageLeading
        newButton.bezelStyle = .regularSquare
        newButton.font = .systemFont(ofSize: 14, weight: .medium)
        newButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
        newButton.rounded(12, fill: .controlBackgroundColor, border: Theme.separator)

        let sectionLabel = NSTextField(labelWithString: "工作区")
        sectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sectionLabel.textColor = .secondaryLabelColor

        searchField.placeholderString = "搜索会话…"
        searchField.delegate = self
        searchField.controlSize = .small

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.rowHeight = 42
        tableView.selectionHighlightStyle = .none
        tableView.delegate = self
        tableView.dataSource = self
        tableView.menu = sessionMenu()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tableView

        emptyLabel.alignment = .center
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        let settings = HoverButton(title: "设置", target: self, action: #selector(showSettings))
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        settings.alignment = .left
        settings.isBordered = false
        settings.rounded(9)
        settings.heightAnchor.constraint(equalToConstant: 38).isActive = true

        for child in [brandRow, newButton, sectionLabel, searchField, scroll, emptyLabel, settings] { root.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            brandRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), brandRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), brandRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 30), brandRow.heightAnchor.constraint(equalToConstant: 40),
            newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), newButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), newButton.topAnchor.constraint(equalTo: brandRow.bottomAnchor, constant: 10),
            sectionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), sectionLabel.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), searchField.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 9), searchField.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6), scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 30),
            settings.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), settings.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), settings.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
    }

    func setSessions(_ sessions: [SessionSummary], currentId: String?) {
        allSessions = sessions.filter { !$0.blank || $0.id == currentId }
        self.currentId = currentId
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = query.isEmpty ? allSessions : allSessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.cwd?.localizedCaseInsensitiveContains(query) ?? false) }
        emptyLabel.isHidden = !filtered.isEmpty
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = filtered[row]
        let cell = HoverButton(title: session.displayTitle, target: self, action: #selector(selectRow(_:)))
        cell.tag = row
        cell.isBordered = false
        cell.alignment = .left
        cell.font = .systemFont(ofSize: 13.5, weight: session.id == currentId ? .medium : .regular)
        cell.lineBreakMode = .byTruncatingTail
        cell.image = NSImage(systemSymbolName: session.running ? "circle.dotted" : "message", accessibilityDescription: nil)
        cell.imagePosition = .imageLeading
        cell.contentTintColor = session.running ? Theme.blue : .secondaryLabelColor
        cell.rounded(9, fill: session.id == currentId ? Theme.subtleFill : .clear)
        return cell
    }

    private func sessionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "重命名…", action: #selector(renameSelected), keyEquivalent: "")
        return menu
    }

    @objc private func selectRow(_ sender: NSButton) { guard filtered.indices.contains(sender.tag) else { return }; delegate?.sidebar(self, didSelect: filtered[sender.tag]) }
    @objc private func newSession() { delegate?.sidebarDidRequestNewSession(self) }
    @objc private func showSettings() { delegate?.sidebarDidRequestSettings(self) }
    @objc private func renameSelected() { let row = tableView.clickedRow; guard filtered.indices.contains(row) else { return }; delegate?.sidebar(self, didRequestRename: filtered[row]) }
}
