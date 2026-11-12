import LodgeKit
import SwiftUI

@main
struct LodgeApp: App {
    @State private var browser = BrowserModel()

    var body: some Scene {
        Window("Lodge", id: "browser") {
            BrowserView(model: browser)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { BrowserCommands(model: browser) }
    }
}
