import LodgeKit
import SwiftUI

/// The workspace on screen; opens the list to switch to another, make a new one, edit this one or open Settings.
struct WorkspaceMenu: View {
    @Environment(AppModel.self) private var model
    @State private var editing: WorkspaceEditor.Mode?

    var body: some View {
        Menu {
            Picker(
                "Workspaces",
                selection: Binding(get: { model.activeID }, set: { model.switchTo($0) })
            ) {
                ForEach(model.workspaces.workspaces) { workspace in
                    Label(workspace.name, systemImage: workspace.symbol).tag(workspace.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Workspace…", systemImage: "plus") { editing = .create }
            Button("Edit Workspace…", systemImage: "pencil") { editing = .edit(model.active) }
            Button("Settings", systemImage: "gearshape") { model.showsSettings = true }
        } label: {
            Label(model.active.name, systemImage: model.active.symbol)
        }
        .sheet(item: $editing) { mode in WorkspaceEditor(mode: mode) }
    }
}
