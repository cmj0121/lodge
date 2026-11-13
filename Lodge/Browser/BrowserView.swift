import LodgeKit
import SwiftUI

/// The browser window: every control in the left column, and the selected tab's page floating as
/// a card on the right.
struct BrowserView: View {
    let pane: BrowserPane
    @AppStorage(SidebarMode.defaultsKey) private var sidebarMode: SidebarMode = .expanded

    var body: some View {
        HStack(spacing: 0) {
            TabSidebar(pane: pane, mode: sidebarMode) {
                pane.closeDownloadsForModeChange()
                withAnimation(.snappy(duration: 0.25)) { sidebarMode = sidebarMode.toggled }
            }
            .frame(width: sidebarMode.width)
            PageCard(pane: pane, showsAddress: sidebarMode == .rail)
                .padding([.top, .trailing, .bottom], 8)
                // The card reaches up beside the window buttons; the column keeps the title bar inset.
                .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if pane.window.isShortcutHelpVisible {
                ShortcutHelpOverlay(close: pane.hideShortcutHelp)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let prompt = pane.window.locationPrompt {
                LocationPromptView(
                    prompt: prompt, initialText: prompt.initialText(for: address(of: prompt)),
                    submit: pane.submitLocation, cancel: pane.cancelLocationPrompt
                )
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: pane.window.isShortcutHelpVisible)
        .animation(.snappy(duration: 0.2), value: pane.window.locationPrompt)
        .navigationTitle(pane.windowTitle)
        .environment(\.webViewRegistry, pane.model.registry)
        .frame(minWidth: 800, minHeight: 500)
        .focusedSceneValue(\.isBrowserWindow, true)
    }

    private func address(of prompt: LocationPrompt) -> URL? {
        guard case .current(let id) = prompt else { return nil }
        return pane.model.tabs[id]?.url
    }
}

extension FocusedValues {
    /// Set by browser windows, so ⌘W closes a tab there and the window anywhere else.
    @Entry var isBrowserWindow: Bool?
}

/// The page, as a floating card. With the sidebar collapsed it carries the address and navigation
/// in a header strip.
private struct PageCard: View {
    let pane: BrowserPane
    let showsAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsAddress {
                HStack(spacing: 8) {
                    NavigationButtons(pane: pane)
                    AddressBar(pane: pane)
                        .frame(maxWidth: 640)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            PageArea(pane: pane)
                .overlay(alignment: .topTrailing) {
                    if pane.window.isFindVisible {
                        FindPopup(pane: pane, window: pane.window)
                            .padding(12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: pane.window.isFindVisible)
        }
        .floatingSurface(cornerRadius: 10)
    }
}

private struct PageArea: View {
    let pane: BrowserPane

    private var tab: BrowserTab? { pane.selected }
    /// No tab, or a blank one with nothing on its way.
    private var showsNewTab: Bool { tab.map { $0.url == nil && !$0.isLoading } ?? true }

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let tab {
                WebViewHost(tab: tab.id)
            }
            if let tab, tab.hasCrashed {
                CrashedPlaceholder(host: tab.url?.host(), reload: pane.reload)
            } else if showsNewTab {
                NewTabPlaceholder()
            }
        }
    }
}

private struct NewTabPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "New Tab", systemImage: "square.on.square.dashed",
            description: Text("Type an address or a search in the address bar."))
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
