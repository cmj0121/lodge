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
            BrowserRoot(coordinator: appDelegate.coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .commands { BrowserCommands(coordinator: appDelegate.coordinator, history: appDelegate.history) }

        Window("History", id: "history") {
            HistoryView(model: appDelegate.history)
        }
        .defaultSize(width: 640, height: 600)

        Settings {
            SettingsView()
        }
    }
}

/// The browser window, showing the workspace its window has active; a switch builds it afresh for that workspace.
struct BrowserRoot: View {
    let coordinator: WorkspaceCoordinator

    var body: some View {
        let model = coordinator.active
        BrowserView(model: model)
            .id(model.workspaceID)
    }
}
