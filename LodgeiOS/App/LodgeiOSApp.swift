import LodgeKit
import SwiftUI

@main
struct LodgeiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    if ExternalLink.accepts(url) { model.newTab(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.flush() }
        }
    }
}
