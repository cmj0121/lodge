import LodgeKit
import SwiftUI

/// One field for an address or a search. At rest it shows the page's host; editing shows the whole address,
/// selected, so typing replaces it.
struct AddressField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isEditing: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 6) {
            Image(systemName: icon(for: tab))
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Search or enter address", text: $text, selection: $selection)
                .focused($isEditing)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .multilineTextAlignment(isEditing ? .leading : .center)
                .onSubmit {
                    model.go(text)
                    isEditing = false
                }
            if isEditing, !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else if !isEditing, let tab, tab.url != nil {
                let title: LocalizedStringKey = tab.isLoading ? "Stop" : "Reload"
                Button(title, systemImage: tab.isLoading ? "xmark" : "arrow.clockwise") {
                    guard model.pool.hasView(tab.id) else { return }
                    let view = model.pool.view(for: tab.id)
                    if tab.isLoading { view.stopLoading() } else { view.reload() }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.fill.tertiary, in: .capsule)
        .onAppear { text = resting(tab) }
        .onChange(of: tab?.url) { if !isEditing { text = resting(model.selectedTab) } }
        .onChange(of: tab?.id) {
            text = resting(model.selectedTab)
            // A blank tab asks for an address at once, as Safari's does.
            if let tab = model.selectedTab, tab.url == nil, !tab.isLive { isEditing = true }
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                text = model.selectedTab?.url?.absoluteString ?? ""
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else {
                text = resting(model.selectedTab)
            }
        }
    }

    private func resting(_ tab: BrowserTab?) -> String {
        guard let url = tab?.url else { return "" }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    private func icon(for tab: BrowserTab?) -> String {
        if isEditing || tab?.url == nil { return "magnifyingglass" }
        return tab?.url?.scheme?.lowercased() == "https" ? "lock.fill" : "globe"
    }
}
