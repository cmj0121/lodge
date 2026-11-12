import LodgeKit
import SwiftUI

/// The browser window: vertical tabs in the sidebar, a compact toolbar, the selected tab's page.
struct BrowserView: View {
    @Bindable var model: BrowserModel
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            TabSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if model.isFindVisible {
                    FindBar(model: model)
                    Divider()
                }
                PageArea(model: model)
            }
            .toolbar { BrowserToolbar(model: model) }
        }
        .navigationTitle(model.selected?.displayTitle ?? "Lodge")
        .environment(\.webViewRegistry, model.registry)
        .frame(minWidth: 800, minHeight: 500)
    }
}

private struct PageArea: View {
    let model: BrowserModel

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let tab = model.selected {
                WebViewHost(tab: tab.id)
                if tab.hasCrashed {
                    CrashedPlaceholder(host: tab.url?.host(), reload: model.reload)
                } else if tab.url == nil && !tab.isLoading {
                    ContentUnavailableView(
                        "New Tab", systemImage: "square.on.square.dashed",
                        description: Text("Type an address or a search in the address bar."))
                }
            }
        }
    }
}

private struct CrashedPlaceholder: View {
    let host: String?
    let reload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("This page stopped working", systemImage: "exclamationmark.triangle")
        } description: {
            Text(
                host.map { "The web content process for \($0) ended unexpectedly." }
                    ?? "The web content process ended unexpectedly.")
        } actions: {
            Button("Reload Page", action: reload)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
