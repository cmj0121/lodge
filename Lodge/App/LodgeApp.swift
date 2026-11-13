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
        // session.json rebuilds the windows; macOS's own restoration would keep an Anonymous page's title.
        .restorationBehavior(.disabled)
        .commands { BrowserCommands(coordinator: appDelegate.coordinator, history: appDelegate.history) }

        Window("History", id: "history") {
            HistoryView(model: appDelegate.history)
        }
        .defaultSize(width: 640, height: 600)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

/// The browser window, showing the workspace its window has active; a switch builds it afresh for that workspace.
/// The workspace sheet floats over it, outside that rebuild, so creating a workspace can switch under it.
struct BrowserRoot: View {
    let coordinator: WorkspaceCoordinator

    var body: some View {
        let model = coordinator.active
        let window = coordinator.window
        BrowserView(model: model)
            .id(model.workspaceID)
            .environment(coordinator)
            .overlay {
                if let editor = window.workspaceEditor {
                    WorkspaceSheet(coordinator: coordinator, editor: editor) { coordinator.active.finishWorkspaceEditor() }
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: window.workspaceEditor)
    }
}
