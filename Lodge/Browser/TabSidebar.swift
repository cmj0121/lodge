import LodgeKit
import SwiftUI

/// Vertical tab list with a new-tab button underneath.
struct TabSidebar: View {
    let model: BrowserModel

    private var selection: Binding<TabID?> {
        Binding(
            get: { model.tabs.selectedID },
            set: { id in if let id { model.select(id) } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(model.tabs.tabs) { tab in
                TabRow(tab: tab, isSelected: tab.id == model.tabs.selectedID) { model.close(tab.id) }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: model.newTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .help("Open a new tab (⌘T)")
        }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isSelected: Bool
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16, height: 16)
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

    @ViewBuilder private var icon: some View {
        if tab.hasCrashed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if tab.isLoading {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: tab.url == nil ? "square.dashed" : "globe")
                .foregroundStyle(.secondary)
        }
    }
}
