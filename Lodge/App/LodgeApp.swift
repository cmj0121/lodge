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
        .commands { BrowserCommands(model: appDelegate.browser, history: appDelegate.history) }

        Window("History", id: "history") {
            HistoryView(model: appDelegate.history)
        }
        .defaultSize(width: 640, height: 600)

        Settings {
            Text("No settings yet.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}
