import AppKit
import SwiftUI

/// Opaque dynamic sidebar fill. The WebUI/sidebar contract uses the system
/// sidebar color, while Liquid Glass is reserved for transient popovers.
struct NativeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.sidebar.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.backgroundColor = Theme.sidebar.cgColor
    }
}

/// The navigation column deliberately uses the system sidebar material on
/// every OS. Liquid Glass belongs to transient controls, not this surface.
struct NativeSystemSidebar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.background(NativeSidebarMaterial().ignoresSafeArea())
    }
}

/// Reports reader-owned scroll movement and document-height changes from the
/// NSScrollView backing SwiftUI's conversation ScrollView. Keeping these two
/// signals separate prevents streaming growth from being mistaken for the
/// reader scrolling away from the bottom.
struct NativeConversationScrollObserver: NSViewRepresentable {
    let onPositionChange: (Bool) -> Void
    let onContentResize: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPositionChange: onPositionChange, onContentResize: onContentResize)
    }

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.onPositionChange = onPositionChange
        context.coordinator.onContentResize = onContentResize
        context.coordinator.attach(from: nsView)
    }

    final class ProbeView: NSView {
        private weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.attach(from: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(from: self)
        }
    }

    final class Coordinator {
        var onPositionChange: (Bool) -> Void
        var onContentResize: () -> Void
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var userScrolling = false
        private var pendingPositionReport = false
        private var pendingIsAtBottom = true

        init(onPositionChange: @escaping (Bool) -> Void,
             onContentResize: @escaping () -> Void) {
            self.onPositionChange = onPositionChange
            self.onContentResize = onContentResize
        }

        func attach(from probe: NSView) {
            DispatchQueue.main.async { [weak self, weak probe] in
                guard let self, let probe, let scrollView = probe.enclosingScrollView else { return }
                guard self.scrollView !== scrollView else { return }
                self.detach()
                self.scrollView = scrollView

                let clip = scrollView.contentView
                clip.postsBoundsChangedNotifications = true
                self.boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    guard self?.userScrolling == true else { return }
                    self?.reportPosition()
                }

                self.liveScrollStartObserver = NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in self?.userScrolling = true }
                self.liveScrollEndObserver = NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    self?.reportPosition()
                    self?.userScrolling = false
                }

                if let document = scrollView.documentView {
                    document.postsFrameChangedNotifications = true
                    self.frameObserver = NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: document,
                        queue: .main
                    ) { [weak self] _ in self?.onContentResize() }
                }
                self.reportPosition()
            }
        }

        private func reportPosition() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let visible = scrollView.documentVisibleRect
            let bounds = document.bounds
            let distance: CGFloat
            if document.isFlipped {
                distance = bounds.maxY - visible.maxY
            } else {
                distance = visible.minY - bounds.minY
            }
            let isAtBottom = distance <= 24.5
            pendingIsAtBottom = isAtBottom

            // NSScrollView can emit bounds changes while SwiftUI is still
            // updating the representable hierarchy. Mutating @State from that
            // notification can start another view update in the same
            // transaction, where ScrollViewProxy access is forbidden. Coalesce
            // reports and cross a run-loop boundary before invoking SwiftUI.
            guard !pendingPositionReport else { return }
            pendingPositionReport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingPositionReport = false
                self.onPositionChange(self.pendingIsAtBottom)
            }
        }

        private func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
            if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
            boundsObserver = nil
            frameObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
            userScrolling = false
            scrollView = nil
        }

        deinit { detach() }
    }
}

/// Repository popovers use Liquid Glass on macOS 26 and the native popover
/// material on older systems. Keep this opt-in so ordinary panes never gain
/// an unintended glass sheet.
struct NativeGlassPopoverSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func nativeGlassPopover(cornerRadius: CGFloat = 22) -> some View {
        NativeGlassPopoverSurface(cornerRadius: cornerRadius) { self }
    }
}

/// Captures the actual SwiftUI hosting window. This is more reliable than
/// scanning NSApp.windows while WindowGroup is restoring auxiliary windows.
struct MainWindowConfigurator: NSViewRepresentable {
    let trailingPreset: String?
    let backgroundJobs: [BackgroundJob]
    let currentSession: SessionSummary?
    let allSessions: [SessionSummary]
    let subagentCatalogs: [String: [SubagentEntry]]
    let subagentCount: Int
    let runningSubagentCount: Int
    let refreshSubagents: (String) -> Void
    let openSubagent: (SubagentEntry, String) -> Void
    let interruptSubagent: (SubagentEntry, String) -> Void
    let sessionLogExportBusy: Bool
    let exportSessionLog: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(preset: trailingPreset,
                    backgroundJobs: backgroundJobs,
                    currentSession: currentSession,
                    allSessions: allSessions,
                    subagentCatalogs: subagentCatalogs,
                    subagentCount: subagentCount,
                    runningSubagentCount: runningSubagentCount,
                    refreshSubagents: refreshSubagents,
                    openSubagent: openSubagent,
                    interruptSubagent: interruptSubagent,
                    sessionLogExportBusy: sessionLogExportBusy,
                    exportSessionLog: exportSessionLog)
    }

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {
        context.coordinator.update(preset: trailingPreset,
                                   backgroundJobs: backgroundJobs,
                                   currentSession: currentSession,
                                   allSessions: allSessions,
                                   subagentCatalogs: subagentCatalogs,
                                   subagentCount: subagentCount,
                                   runningSubagentCount: runningSubagentCount,
                                   refreshSubagents: refreshSubagents,
                                   openSubagent: openSubagent,
                                   interruptSubagent: interruptSubagent,
                                   sessionLogExportBusy: sessionLogExportBusy,
                                   exportSessionLog: exportSessionLog,
                                   window: nsView.window)
    }

    final class Coordinator {
        private var preset: String?
        private var backgroundJobs: [BackgroundJob]
        private var currentSession: SessionSummary?
        private var allSessions: [SessionSummary]
        private var subagentCatalogs: [String: [SubagentEntry]]
        private var subagentCount: Int
        private var runningSubagentCount: Int
        private var refreshSubagents: (String) -> Void
        private var openSubagent: (SubagentEntry, String) -> Void
        private var interruptSubagent: (SubagentEntry, String) -> Void
        private var sessionLogExportBusy: Bool
        private var exportSessionLog: () -> Void
        private weak var installedWindow: NSWindow?
        private var accessoryController: NSTitlebarAccessoryViewController?
        private var hostingView: NSHostingView<TrailingTitlebarActions>?

        init(preset: String?, backgroundJobs: [BackgroundJob], currentSession: SessionSummary?,
             allSessions: [SessionSummary], subagentCatalogs: [String: [SubagentEntry]],
             subagentCount: Int, runningSubagentCount: Int,
             refreshSubagents: @escaping (String) -> Void,
             openSubagent: @escaping (SubagentEntry, String) -> Void,
             interruptSubagent: @escaping (SubagentEntry, String) -> Void,
             sessionLogExportBusy: Bool, exportSessionLog: @escaping () -> Void) {
            self.preset = preset
            self.backgroundJobs = backgroundJobs
            self.currentSession = currentSession
            self.allSessions = allSessions
            self.subagentCatalogs = subagentCatalogs
            self.subagentCount = subagentCount
            self.runningSubagentCount = runningSubagentCount
            self.refreshSubagents = refreshSubagents
            self.openSubagent = openSubagent
            self.interruptSubagent = interruptSubagent
            self.sessionLogExportBusy = sessionLogExportBusy
            self.exportSessionLog = exportSessionLog
        }

        func update(preset: String?,
                    backgroundJobs: [BackgroundJob],
                    currentSession: SessionSummary?,
                    allSessions: [SessionSummary],
                    subagentCatalogs: [String: [SubagentEntry]],
                    subagentCount: Int,
                    runningSubagentCount: Int,
                    refreshSubagents: @escaping (String) -> Void,
                    openSubagent: @escaping (SubagentEntry, String) -> Void,
                    interruptSubagent: @escaping (SubagentEntry, String) -> Void,
                    sessionLogExportBusy: Bool,
                    exportSessionLog: @escaping () -> Void,
                    window: NSWindow?) {
            self.preset = preset
            self.backgroundJobs = backgroundJobs
            self.currentSession = currentSession
            self.allSessions = allSessions
            self.subagentCatalogs = subagentCatalogs
            self.subagentCount = subagentCount
            self.runningSubagentCount = runningSubagentCount
            self.refreshSubagents = refreshSubagents
            self.openSubagent = openSubagent
            self.interruptSubagent = interruptSubagent
            self.sessionLogExportBusy = sessionLogExportBusy
            self.exportSessionLog = exportSessionLog
            installOrUpdate(in: window)
        }

        func installOrUpdate(in window: NSWindow?) {
            guard let window else { return }

            if installedWindow !== window {
                removeAccessory()
                installedWindow = window
            }

            guard let preset else {
                removeAccessory()
                installedWindow = window
                return
            }

            let content = TrailingTitlebarActions(
                preset: preset,
                jobs: backgroundJobs,
                session: currentSession,
                sessions: allSessions,
                subagentCatalogs: subagentCatalogs,
                subagentCount: subagentCount,
                runningSubagentCount: runningSubagentCount,
                refreshSubagents: refreshSubagents,
                openSubagent: openSubagent,
                interruptSubagent: interruptSubagent,
                sessionLogExportBusy: sessionLogExportBusy,
                exportSessionLog: exportSessionLog
            )

            if let hostingView {
                hostingView.rootView = content
                hostingView.invalidateIntrinsicContentSize()
                hostingView.frame.size = hostingView.fittingSize
                return
            }

            let hostingView = NSHostingView(rootView: content)
            hostingView.sizingOptions = [.intrinsicContentSize]
            // NSTitlebarAccessoryViewController positions a right accessory
            // from the view's current width. NSHostingView otherwise begins at
            // zero width and grows out past the window's trailing edge.
            hostingView.frame.size = hostingView.fittingSize
            let controller = NSTitlebarAccessoryViewController()
            controller.layoutAttribute = .right
            controller.view = hostingView
            window.addTitlebarAccessoryViewController(controller)
            self.hostingView = hostingView
            self.accessoryController = controller
        }

        private func removeAccessory() {
            if let controller = accessoryController,
               let window = installedWindow,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === controller }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessoryController = nil
            hostingView = nil
        }

        deinit { removeAccessory() }
    }

    final class WindowProbe: NSView {
        private let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            coordinator.installOrUpdate(in: window)
            window.isRestorable = false
            DispatchQueue.main.async { Self.repair(window) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Self.repair(window) }
        }

        private static func repair(_ window: NSWindow) {
            // NavigationSplitView owns the real native sidebar and unified
            // toolbar. Keep that toolbar visible: session title, mode and log
            // actions live in actual window chrome rather than a fake row.
            // RootView supplies the current conversation through
            // `.navigationTitle`. Let AppKit draw that single native title;
            // hiding it previously forced a duplicate hand-built toolbar label.
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbarStyle = .unified
            window.toolbar?.isVisible = true
            window.toolbar?.showsBaselineSeparator = false
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
            let intersection = window.frame.intersection(visible)
            if window.frame.width < 900 || window.frame.height < 560 || intersection.width < 240 || intersection.height < 160 {
                let width = min(1320, visible.width - 40)
                let height = min(840, visible.height - 40)
                window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct TrailingTitlebarActions: View {
    let preset: String
    let jobs: [BackgroundJob]
    let session: SessionSummary?
    let sessions: [SessionSummary]
    let subagentCatalogs: [String: [SubagentEntry]]
    let subagentCount: Int
    let runningSubagentCount: Int
    let refreshSubagents: (String) -> Void
    let openSubagent: (SubagentEntry, String) -> Void
    let interruptSubagent: (SubagentEntry, String) -> Void
    let sessionLogExportBusy: Bool
    let exportSessionLog: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if let session {
                TitlebarSubagentCatalog(
                    session: session,
                    sessions: sessions,
                    catalogs: subagentCatalogs,
                    descendantCount: subagentCount,
                    runningCount: runningSubagentCount,
                    refresh: refreshSubagents,
                    openChild: openSubagent,
                    interrupt: interruptSubagent
                )
            }
            if !jobs.isEmpty {
                JobListMenu(jobs: jobs)
            }
            HStack(spacing: 7) {
                DeepSeekIcon(kind: .sparkle, size: 14)
                    .foregroundStyle(.tertiary)
                Text(preset)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))

            Button(action: exportSessionLog) {
                HStack(spacing: 4) {
                    Text("Session log")
                    DeepSeekIcon(kind: .download, size: 12)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 111, minHeight: 32)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .overlay(Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 1))
            .disabled(sessionLogExportBusy)
            .help("下载当前 Session、子 Session 和附件的 ZIP")
        }
        .fixedSize()
        .padding(.trailing, 10)
        .frame(height: 38)
    }
}

/// WebUI-compatible titlebar entry point for durable child conversations.
/// The trigger counts the full descendant tree; the popover initially shows
/// direct children and hydrates deeper catalogs only when disclosed.
private struct TitlebarSubagentCatalog: View {
    let session: SessionSummary
    let sessions: [SessionSummary]
    let catalogs: [String: [SubagentEntry]]
    let descendantCount: Int
    let runningCount: Int
    let refresh: (String) -> Void
    let openChild: (SubagentEntry, String) -> Void
    let interrupt: (SubagentEntry, String) -> Void
    @State private var presented = false

    private var directChildren: [SubagentEntry] { catalogs[session.id] ?? [] }
    private var healthyDirectCount: Int { directChildren.filter { !$0.isDiagnostic }.count }
    private var displayCount: Int { max(descendantCount, healthyDirectCount) }
    private var visible: Bool { displayCount > 0 || directChildren.contains(where: \.isDiagnostic) }

    var body: some View {
        if visible {
            Button {
                presented.toggle()
                if presented { refresh(session.id) }
            } label: {
                HStack(spacing: 5) {
                    Group {
                        if runningCount > 0 {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                .shadow(color: Color.green.opacity(0.28), radius: 2)
                        } else {
                            Color.clear.frame(width: 8, height: 8)
                        }
                    }
                    Text("\(displayCount) 个子代理")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(presented ? 180 : 0))
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(runningCount > 0 ? "\(runningCount) 个子代理正在运行" : "\(displayCount) 个子代理")
            .popover(isPresented: $presented, arrowEdge: .top) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if directChildren.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载子代理…").foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12)).padding(12)
                        } else {
                            ForEach(directChildren) { entry in
                                TitlebarSubagentRow(
                                    entry: entry,
                                    parentID: session.id,
                                    sessions: sessions,
                                    catalogs: catalogs,
                                    depth: 0,
                                    refresh: refresh,
                                    openChild: { child, parent in
                                        presented = false
                                        openChild(child, parent)
                                    },
                                    interrupt: interrupt
                                )
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(width: 336)
                .frame(minHeight: 58, maxHeight: 520)
                .nativeGlassPopover(cornerRadius: 12)
            }
            .onChange(of: session.id) { _ in presented = false }
        }
    }
}

private struct TitlebarSubagentRow: View {
    let entry: SubagentEntry
    let parentID: String
    let sessions: [SessionSummary]
    let catalogs: [String: [SubagentEntry]]
    let depth: Int
    let refresh: (String) -> Void
    let openChild: (SubagentEntry, String) -> Void
    let interrupt: (SubagentEntry, String) -> Void
    @State private var expanded = false
    @State private var hovering = false

    private var summary: SessionSummary? { sessions.first { $0.id == entry.id } }
    private var statusColor: Color { entry.activity == "running" ? .green : .secondary }
    private var label: String { entry.label ?? entry.id }
    private var secondary: String {
        let values = [summary?.title,
                      entry.mode == "one-shot" ? "一次性" : "可继续",
                      entry.activity == "running" ? "正在运行" : "当前未运行"]
        return values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var tokenText: String? {
        guard let usage = entry.tokenUsage ?? summary?.tokenUsage else { return nil }
        return "\(compactTokens(usage.uncachedInput + usage.output + usage.cacheRead + usage.cacheWrite)) tok"
    }
    private var durationText: String? {
        guard let milliseconds = entry.durationMs else { return nil }
        return compactDuration(milliseconds)
    }

    var body: some View {
        if entry.isDiagnostic {
            HStack(alignment: .top, spacing: 8) {
                if depth == 0 { Color.clear.frame(width: 14) }
                Circle().fill(Color.red).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.id).lineLimit(1)
                    Text(entry.diagnostic ?? "会话记录暂不可用")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.system(size: 13)).padding(.horizontal, 8).padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    if entry.hasChildren {
                        Button {
                            expanded.toggle()
                            if expanded { refresh(entry.id) }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .frame(width: 14, height: 18)
                        }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                    } else if depth == 0 || catalogs[parentID]?.contains(where: { $0.hasChildren }) == true {
                        Color.clear.frame(width: 14, height: 18)
                    }

                    Button { openChild(entry, parentID) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(statusColor).frame(width: 8, height: 8).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                                Text(secondary).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if tokenText != nil || durationText != nil {
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let tokenText { Text(tokenText) }
                                    if let durationText { Text(durationText) }
                                }
                                .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(hovering ? Color.primary.opacity(0.065) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .contextMenu {
                        if entry.mode == "continuable" && entry.activity == "running" {
                            Button("中断子代理", role: .destructive) { interrupt(entry, parentID) }
                        }
                    }
                }
                .padding(.leading, CGFloat(depth * 18))

                if expanded && entry.hasChildren {
                    let children = catalogs[entry.id] ?? []
                    VStack(alignment: .leading, spacing: 0) {
                        if children.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在加载子代理…").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }.padding(.leading, CGFloat((depth + 1) * 18 + 30)).padding(.vertical, 8)
                        } else {
                            ForEach(children) { child in
                                TitlebarSubagentRow(entry: child, parentID: entry.id, sessions: sessions,
                                                    catalogs: catalogs, depth: depth + 1, refresh: refresh,
                                                    openChild: openChild, interrupt: interrupt)
                            }
                        }
                    }
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                            .padding(.leading, CGFloat((depth + 1) * 18 + 6))
                    }
                }
            }
        }
    }

    private func compactTokens(_ value: Int) -> String {
        if value < 1_000 { return "\(value)" }
        if value < 1_000_000 { return compactNumber(Double(value) / 1_000) + "K" }
        return compactNumber(Double(value) / 1_000_000) + "M"
    }

    private func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }

    private func compactDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds < 60 { return "\(seconds)秒" }
        if seconds < 3_600 { return "\(seconds / 60)分\(seconds % 60)秒" }
        if seconds < 86_400 { return "\(seconds / 3_600)小时\((seconds % 3_600) / 60)分" }
        return "\(seconds / 86_400)天\((seconds % 86_400) / 3_600)小时"
    }
}
