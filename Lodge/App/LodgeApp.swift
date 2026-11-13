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
        // The coordinator opens every browser window itself (restored at launch, ⌘N, Dock reopen), each with its own
        // id; `defaultValue` runs for every window, so it only makes an id.
        WindowGroup("Lodge", id: "browser", for: WindowID.self) { $id in
            BrowserWindowRoot(coordinator: appDelegate.coordinator, id: id)
        } defaultValue: {
            WindowID()
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        // A link from another app goes to the app delegate, never to a new window of any scene.
        .handlesExternalEvents(matching: [])
        .defaultLaunchBehavior(.suppressed)
        // session.json rebuilds the windows; macOS's own restoration would keep an Anonymous page's title.
        .restorationBehavior(.disabled)
        .commands { BrowserCommands(coordinator: appDelegate.coordinator, history: appDelegate.history) }

        Window("History", id: "history") {
            HistoryView(model: appDelegate.history)
        }
        .defaultSize(width: 640, height: 600)
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

/// The browser window with this id: the coordinator's window for it, or one it adopts as a new window (D1) when
/// SwiftUI opened a window the coordinator did not ask for.
struct BrowserWindowRoot: View {
    let coordinator: WorkspaceCoordinator
    let id: WindowID
    @State private var window: WindowState?

    init(coordinator: WorkspaceCoordinator, id: WindowID) {
        self.coordinator = coordinator
        self.id = id
        _window = State(initialValue: coordinator.window(for: id))
    }

    var body: some View {
        if let window {
            BrowserRoot(coordinator: coordinator, window: window)
        } else {
            Color.clear.onAppear { window = coordinator.windowState(for: id) }
        }
    }
}

/// A browser window, showing the active workspace; a switch builds it afresh for that workspace. The workspace
/// sheet floats over it, outside that rebuild, so creating a workspace can switch under it.
struct BrowserRoot: View {
    let coordinator: WorkspaceCoordinator
    let window: WindowState

    var body: some View {
        let pane = coordinator.pane(for: window)
        BrowserView(pane: pane)
            .id(pane.model.workspaceID)
            .environment(coordinator)
            .overlay {
                if let editor = window.workspaceEditor {
                    WorkspaceSheet(coordinator: coordinator, editor: editor) {
                        coordinator.pane(for: window).finishWorkspaceEditor()
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.2), value: window.workspaceEditor)
            .background(WindowRegistrar(coordinator: coordinator, window: window))
    }
}
