import LodgeKit
import SwiftUI

/// Back, forward, the address bar and reload/stop.
struct BrowserToolbar: ToolbarContent {
    let model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward", action: model.goBack)
                .disabled(model.selected?.canGoBack != true)
                .help("Go back (⌘[)")
            Button("Forward", systemImage: "chevron.forward", action: model.goForward)
                .disabled(model.selected?.canGoForward != true)
                .help("Go forward (⌘])")
        }
        ToolbarItem(placement: .principal) {
            AddressBar(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            if model.selected?.isLoading == true {
                Button("Stop", systemImage: "xmark", action: model.stopLoading)
                    .help("Stop loading (⌘.)")
            } else {
                Button("Reload", systemImage: "arrow.clockwise", action: model.reload)
                    .disabled(model.selected?.url == nil)
                    .help("Reload this page (⌘R)")
            }
        }
    }
}

/// The address field: shows the page's address, takes a URL or a search, and hosts the load
/// progress line along its bottom edge.
private struct AddressBar: View {
    let model: BrowserModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var tab: BrowserTab? { model.selected }
    private var isSecure: Bool { tab?.url?.scheme == "https" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSecure ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
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
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(minWidth: 220, idealWidth: 400, maxWidth: 640)
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
        .onChange(of: model.addressFocusRequest) { isFocused = true }
    }

    private var displayedAddress: String { tab?.url?.absoluteString ?? "" }
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

/// Find in page, shown under the toolbar.
struct FindBar: View {
    @Bindable var model: BrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.findMissed {
                Text("Not found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextField("Find on page", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($isFocused)
                .onSubmit(model.findNext)
                .task(id: model.findText) {
                    guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                    model.findIfChanged()
                }
                .onExitCommand(perform: model.hideFind)
            ControlGroup {
                Button("Previous", systemImage: "chevron.up", action: model.findPrevious)
                    .help("Previous match (⇧⌘G)")
                Button("Next", systemImage: "chevron.down", action: model.findNext)
                    .help("Next match (⌘G)")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .disabled(model.findText.isEmpty)
            Button("Done", action: model.hideFind)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { isFocused = true }
        .onChange(of: model.findFocusRequest) { isFocused = true }
    }
}
