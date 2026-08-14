import SwiftUI

@main
struct DeepSeekHarnessMobileApp: App {
    @StateObject private var model = MobileAppModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(model)
                .environmentObject(model.profiles)
                .task { await model.start() }
        }
    }
}
