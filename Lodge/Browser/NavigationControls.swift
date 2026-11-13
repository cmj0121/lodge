import LodgeKit
import SwiftUI

/// Back, forward and reload/stop for the selected tab, as icon buttons.
struct NavigationButtons: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.backward", action: model.goBack)
                .disabled(model.selected?.canGoBack != true)
                .help("Go back")
            Button("Forward", systemImage: "chevron.forward", action: model.goForward)
                .disabled(model.selected?.canGoForward != true)
                .help("Go forward")
            if model.selected?.isLoading == true {
                Button("Stop", systemImage: "xmark", action: model.stopLoading)
                    .help("Stop loading")
            } else {
                Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
                    .disabled(model.selected?.url == nil)
                    .help(ShortcutCatalog.tooltip("Reload this page", for: .reload))
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 4)
    }
}

/// The address field: shows the page's address, takes a URL or a search, and hosts the load
/// progress line along its bottom edge.
struct AddressBar: View {
    let model: BrowserModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var tab: BrowserTab? { model.selected }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    model.load(text)
                    isFocused = false
                }
                .onExitCommand {
                    text = displayedAddress
                    isFocused = false
                }
                .accessibilityLabel("Address")
            SiteSecurityButton(model: model)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(isFocused ? 0.4 : 0.7), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
        }
        .overlay(alignment: .bottomLeading) {
            if let tab, tab.isLoading {
                ProgressLine(model: model, tab: tab.id)
                    .transition(.opacity)
            }
        }
        .onAppear { text = displayedAddress }
        .onChange(of: tab?.id) { text = displayedAddress }
        .onChange(of: tab?.url) { if !isFocused { text = displayedAddress } }
        .onChange(of: isFocused) { if !isFocused { text = displayedAddress } }
    }

    private var displayedAddress: String { tab?.url?.absoluteString ?? "" }
}

/// The live page's security at the address bar's end; a click shows its origin and what the icon means.
private struct SiteSecurityButton: View {
    let model: BrowserModel
    @State private var isShowingInfo = false

    private var url: URL? { model.selected?.url }
    private var security: SiteSecurity { model.selectedSecurity }

    var body: some View {
        Button {
            isShowingInfo = true
        } label: {
            Image(systemName: security.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(security == .none)
        .help("Site information")
        .accessibilityLabel("Site information")
        .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Label(url.map { Origin(url: $0).description } ?? "", systemImage: security.symbol)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(security.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
        }
    }

    private var tint: Color {
        switch security {
        case .mixed: .orange
        case .insecure: .red
        default: .secondary
        }
    }
}

/// A hairline showing the tab's load progress; it reads the progress itself, so a tick redraws
/// only this line and not the address bar.
private struct ProgressLine: View {
    let model: BrowserModel
    let tab: TabID

    var body: some View {
        let progress = model.loadProgress[tab] ?? 0
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: max(proxy.size.width * progress, 12), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }
}
