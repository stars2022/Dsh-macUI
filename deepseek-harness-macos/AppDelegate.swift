import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var fallbackWindow: NSWindow?
    private let primaryModel = AppModel.shared
    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    func application(_ app: NSApplication, shouldRestoreWindowWithIdentifier identifier: NSUserInterfaceItemIdentifier,
                     state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        createFallbackWindowIfNeeded()
        // SwiftUI can apply a restored frame after the first scene appears.
        // Audit a few launch phases so a stale off-screen frame never wins.
        for delay in [0.0, 0.4, 1.2, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.repairMainWindowIfNeeded(force: false)
            }
        }
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.createFallbackWindowIfNeeded() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        repairMainWindowIfNeeded(force: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    private func repairMainWindowIfNeeded(force: Bool) {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && ($0.title == "DeepSeek Harness" || $0.canBecomeMain) }) else { return }
        window.isRestorable = false
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = window.frame
        let usableIntersection = frame.intersection(visible)
        let invalid = frame.width < 900
            || frame.height < 560
            || usableIntersection.width < 240
            || usableIntersection.height < 160
        if force || invalid {
            let width = min(1320, visible.width - 40)
            let height = min(840, visible.height - 40)
            let repaired = NSRect(
                x: visible.midX - width / 2,
                y: visible.midY - height / 2,
                width: width,
                height: height
            )
            window.setFrame(repaired, display: true, animate: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Some macOS state-restoration combinations suppress SwiftUI's initial
    /// Window scene entirely. Keep an AppKit-owned native host as a launch
    /// safety net; normal launches never enter this path.
    private func createFallbackWindowIfNeeded() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let usable = NSApp.windows.first { window in
            guard window.canBecomeMain, !((window) is NSPanel) else { return false }
            let intersection = window.frame.intersection(visible)
            return window.frame.width >= 900 && window.frame.height >= 560 && intersection.width >= 240 && intersection.height >= 160
        }
        if let usable {
            usable.makeKeyAndOrderFront(nil)
            return
        }
        for window in NSApp.windows where window.frame.width < 900 || window.frame.height < 560 { window.orderOut(nil) }
        let content = RootView().environmentObject(primaryModel)
        let controller = NSHostingController(rootView: content)
        let width = min(1320, visible.width - 40), height = min(840, visible.height - 40)
        let window = NSWindow(contentRect: NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "DeepSeek Harness"
        window.titlebarAppearsTransparent = true
        window.isRestorable = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        fallbackWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        primaryModel.start()
        NSApp.activate(ignoringOtherApps: true)
    }
}
