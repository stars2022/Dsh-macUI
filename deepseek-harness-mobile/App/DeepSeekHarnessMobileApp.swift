import SwiftUI

@main
struct DeepSeekHarnessMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MobileAppModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(model)
                .environmentObject(model.profiles)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    model.setSceneActive(phase == .active)
                }
        }
    }
}
