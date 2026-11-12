import LodgeKit
import SwiftUI

extension SidebarMode {
    /// Column width in points; the rail is just wide enough for the window buttons over its top.
    var width: CGFloat { self == .expanded ? 240 : 72 }
}

/// The left column: the full control sidebar, or the icon-only rail.
struct TabSidebar: View {
    let model: BrowserModel
    let mode: SidebarMode
    let toggle: () -> Void

    var body: some View {
        switch mode {
        case .expanded: ExpandedSidebar(model: model, toggle: toggle)
        case .rail: RailSidebar(model: model, toggle: toggle)
        }
    }
}

/// Workspace, address, navigation, the tab list with titles, New Tab and Settings.
private struct ExpandedSidebar: View {
    let model: BrowserModel
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WorkspaceMenu(compact: false)
                Spacer(minLength: 0)
                SidebarToggle(isRail: false, action: toggle)
            }
            AddressBar(model: model)
            NavigationButtons(model: model)
            Divider()
            TabListView(model: model) { tab, isSelected in
                TabRow(tab: tab, icon: model.favicons[tab.id], isSelected: isSelected) { model.close(tab.id) }
            }
            HStack {
                NewTabButton(model: model)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
                SettingsButton()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

/// Icons only: workspace, expand, one icon per tab, New Tab and Settings.
private struct RailSidebar: View {
    let model: BrowserModel
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            WorkspaceMenu(compact: true)
            SidebarToggle(isRail: true, action: toggle)
            Divider()
            TabListView(model: model) { tab, _ in
                TabIcon(tab: tab, image: model.favicons[tab.id])
                    .frame(maxWidth: .infinity)
                    .help(tab.displayTitle)
            }
            NewTabButton(model: model)
            SettingsButton()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// The selectable tab list with its context menu; `row` draws each tab.
private struct TabListView<Row: View>: View {
    let model: BrowserModel
    @ViewBuilder let row: (BrowserTab, Bool) -> Row

    private var selection: Binding<TabID?> {
        Binding(
            get: { model.tabs.selectedID },
            set: { id in if let id { model.select(id) } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.tabs.tabs) { tab in
                row(tab, tab.id == model.tabs.selectedID)
                    .tag(tab.id)
                    .contextMenu {
                        Button("Reload") {
                            model.select(tab.id)
                            model.reload()
                        }
                        Divider()
                        Button("Close Tab") { model.close(tab.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct SidebarToggle: View {
    let isRail: Bool
    let action: () -> Void

    var body: some View {
        let verb = isRail ? "Expand" : "Collapse"
        Button("\(verb) Sidebar", systemImage: "sidebar.left", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("\(verb) the sidebar (⌃⌘S)")
    }
}

private struct NewTabButton: View {
    let model: BrowserModel

    var body: some View {
        Button("New Tab", systemImage: "plus", action: model.newTab)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open a new tab (⌘T)")
    }
}

private struct SettingsButton: View {
    var body: some View {
        SettingsLink { Label("Settings", systemImage: "gearshape") }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
    }
}

/// A tab's status at icon size: crashed, loading, its favicon, or a placeholder.
private struct TabIcon: View {
    let tab: BrowserTab
    let image: NSImage?

    var body: some View {
        Group {
            if tab.hasCrashed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: tab.url == nil ? "square.dashed" : "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let icon: NSImage?
    let isSelected: Bool
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            TabIcon(tab: tab, image: icon)
            Text(tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Close tab (⌘W)")
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
        .onHover { isHovered = $0 }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}
