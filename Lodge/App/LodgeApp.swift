import LodgeKit
import SwiftUI

@main
struct LodgeApp: App {
    @State private var browser = BrowserModel()

    var body: some Scene {
        Window("Lodge", id: "browser") {
            BrowserView(model: browser)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { BrowserCommands(model: browser) }

        Settings {
            Text("No settings yet.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}
