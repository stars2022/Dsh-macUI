import SwiftUI

@main
struct HarnessMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("DeepSeek Harness", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 650)
                .preferredColorScheme(model.colorScheme)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.createSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("会话") {
                Button("刷新") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("停止当前会话") { model.stop() }
                    .disabled(model.current?.running != true)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(minWidth: 820, idealWidth: 980, minHeight: 600, idealHeight: 720)
                .preferredColorScheme(model.colorScheme)
        }
    }
}
