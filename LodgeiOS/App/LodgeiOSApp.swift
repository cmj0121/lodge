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
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .inactive where old == .active: model.pictureInPicture.appResigning(shown: model.selectedTab?.id)
            case .active: model.pictureInPicture.appActive(shown: model.selectedTab?.id)
            case .background: model.flush()
            default: break
            }
        }
        .commands {
            CommandMenu("Workspaces") {
                ForEach(1...ShortcutID.workspaceSlots.count, id: \.self) { slot in
                    if let workspace = model.workspaces.workspace(forSlot: slot) {
                        Toggle(
                            workspace.name,
                            isOn: Binding(
                                get: { workspace.id == model.activeID }, set: { _ in model.switchTo(slot: slot) })
                        )
                        .keyboardShortcut(KeyboardShortcut(ShortcutCatalog[.workspace(slot: slot)!].combo))
                    }
                }
            }
            CommandMenu("Pins") {
                ForEach(1...ShortcutID.pinSlots.count, id: \.self) { slot in
                    if model.pin(slot: slot) != nil {
                        let shortcut = ShortcutCatalog[.pin(slot: slot)!]
                        Button(shortcut.title) { model.openPin(slot: slot) }
                            .keyboardShortcut(KeyboardShortcut(shortcut.combo))
                    }
                }
            }
        }
    }
}
