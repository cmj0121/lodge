import LodgeKit
import SwiftUI

/// The one workspace there is for now, as the sidebar names it.
let defaultWorkspaceName = "Default"

/// The sidebar's foot: the workspaces, New Workspace and Settings. Only the default workspace
/// exists for now, so it shows selected and New Workspace waits.
struct WorkspaceBar: View {
    let axis: Axis

    var body: some View {
        let isRail = axis == .vertical
        let layout = isRail ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            WorkspaceIcon(isRail: isRail)
            if axis == .horizontal { Spacer(minLength: 0) }
            Button("New Workspace", systemImage: "plus") {}
                .iconButtonStyle()
                .disabled(true)
                .help("Workspaces are coming")
            SettingsButton()
        }
        .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
        .padding(.horizontal, isRail ? 0 : 4)
    }
}

/// The default workspace, shown selected.
private struct WorkspaceIcon: View {
    let isRail: Bool

    var body: some View {
        Image(systemName: "square.stack.3d.up")
            .foregroundStyle(.primary)
            .frame(width: isRail ? 46 : 28, height: isRail ? 36 : 24)
            .background(rowBackground(isSelected: true, isHovered: false, cornerRadius: isRail ? 10 : 6))
            .help("Workspace: \(defaultWorkspaceName)")
            .accessibilityElement()
            .accessibilityLabel("Workspace: \(defaultWorkspaceName)")
            .accessibilityAddTraits(.isSelected)
    }
}

private struct SettingsButton: View {
    var body: some View {
        SettingsLink { Label("Settings", systemImage: "gearshape") }
            .iconButtonStyle()
            .help("Settings (⌘,)")
    }
}
