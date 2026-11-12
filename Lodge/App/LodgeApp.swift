import LodgeKit
import SwiftUI

@main
struct LodgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
            LayoutRenderer.runIfRequested()
        #endif
    }

    var body: some Scene {
        Window("Lodge", id: "browser") {
            BrowserView(model: appDelegate.browser)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { BrowserCommands(model: appDelegate.browser) }

        Settings {
            Text("No settings yet.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}
