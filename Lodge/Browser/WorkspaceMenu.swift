import SwiftUI

/// The workspace switcher. Only the default workspace exists for now, so the menu shows it and
/// keeps the slot for switching.
struct WorkspaceMenu: View {
    let compact: Bool

    var body: some View {
        Menu {
            Toggle("Default", isOn: .constant(true))
            Divider()
            Button("New Workspace…") {}
                .disabled(true)
        } label: {
            if compact {
                Image(systemName: "square.stack.3d.up.fill")
            } else {
                Label("Default", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .help("Workspace: Default")
    }
}
