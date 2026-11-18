import AppKit
import LodgeKit
import SwiftUI

/// Back, forward and reload/stop for the selected tab, as icon buttons.
struct NavigationButtons: View {
    let pane: BrowserPane

    var body: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.backward", action: pane.goBack)
                .disabled(pane.selected?.canGoBack != true)
                .help("Go back")
            Button("Forward", systemImage: "chevron.forward", action: pane.goForward)
                .disabled(pane.selected?.canGoForward != true)
                .help("Go forward")
            if pane.selected?.isLoading == true {
                Button("Stop", systemImage: "xmark", action: pane.stopLoading)
                    .help("Stop loading")
            } else {
                Button("Reload", systemImage: "arrow.clockwise", action: pane.reload)
                    .disabled(pane.selected?.url == nil)
                    .help(ShortcutCatalog.tooltip(String(localized: "Reload this page"), for: .reload))
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 4)
    }
}

/// The address field: shows the page's address, or the search words on a search engine's results page, takes a URL
/// or a search, lists this workspace's suggestions under it while it is edited, and hosts the load progress line
/// along its bottom edge.
struct AddressBar: View {
    let pane: BrowserPane
    /// Narrow homes (the expanded sidebar) keep the Anonymous and engine badges to their icons so the address has room.
    var isCompact = false
    @State private var text = ""
    @State private var isFocused = false
    /// The list while the field is edited, made fresh each time it takes the keys.
    @State private var suggestions: SuggestionModel?
    @Environment(\.workspaceTint) private var tint

    private var tab: BrowserTab? { pane.selected }
    private var resultsPage: (engine: SearchEngine, words: String)? { pane.selectedResultsPage }
    private var hasLeadingBadge: Bool { pane.model.isAnonymous || resultsPage != nil }

    var body: some View {
        HStack(spacing: 6) {
            if pane.model.isAnonymous {
                AnonymousBadge(isCompact: isCompact)
            }
            if let resultsPage, let tab {
                EngineBadge(engine: resultsPage.engine, icon: pane.model.favicons[tab.id], isCompact: isCompact)
            }
            AddressField(
                text: $text, isEditing: $isFocused, address: copiedAddress, suggestions: suggestions,
                completion: suggestions?.completion, panelRows: suggestions?.rows.count ?? 0, icon: pane.icon(for:),
                choose: { pane.open($0, words: suggestions?.words ?? text) },
                submit: { pane.load(text) })
            HStack(spacing: 0) {
                // A tab of its own each, so switching tabs shows the indicator at once and only a read fades it in.
                FingerprintSlot(pane: pane).id(tab?.id)
                SiteSecurityButton(pane: pane)
            }
        }
        .padding(.leading, hasLeadingBadge ? 5 : 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(isFocused ? 0.4 : 0.7), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder((tint?.color ?? .accentColor).opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
        }
        .overlay(alignment: .bottomLeading) {
            if let tab, tab.isLoading {
                ProgressLine(model: pane.model, tab: tab.id)
                    .transition(.opacity)
            }
        }
        .contextMenu {
            Button("Copy Address", action: pane.copyAddress)
                .disabled(tab?.url == nil)
        }
        .onAppear(perform: showAddress)
        .onChange(of: tab?.id) {
            showAddress()
            // The rows were for the text just replaced, and may list the tab now shown.
            if isFocused { suggestions = pane.makeSuggestions() }
        }
        .onChange(of: tab?.url) { if !isFocused { showAddress() } }
        .onChange(of: isFocused) {
            if isFocused {
                suggestions = pane.makeSuggestions()
            } else {
                suggestions = nil
                showAddress()
            }
        }
    }

    /// The words of a results page, else the page's address.
    private func showAddress() {
        text = resultsPage?.words ?? tab?.url?.absoluteString ?? ""
    }

    /// Copy gives the page's full address while the field holds its results page's words unedited, with all or none
    /// of them selected; otherwise it copies the selected text.
    private func copiedAddress(_ text: String, _ selected: NSRange) -> URL? {
        guard let url = tab?.url, let words = resultsPage?.words, text == words,
            selected.length == 0 || selected.length == (text as NSString).length
        else { return nil }
        return url
    }
}

/// At the address field's start on a search results page: the engine's name with the icon the tab already loaded for
/// the page (none fetched for it), else a generic search glyph.
private struct EngineBadge: View {
    let engine: SearchEngine
    let icon: NSImage?
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 12, height: 12)
            if !isCompact {
                Text(verbatim: engine.name)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, isCompact ? 4 : 7)
        .frame(height: 18)
        .background(.fill.secondary, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Search results from \(engine.name)"))
        .help(String(localized: "Search results from \(engine.name)"))
    }
}

/// Marks the address field of an Anonymous window, so it is never mistaken for an ordinary one.
private struct AnonymousBadge: View {
    let isCompact: Bool

    var body: some View {
        Group {
            if isCompact {
                label.labelStyle(.iconOnly)
            } else {
                label.labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, isCompact ? 5 : 7)
        .frame(height: 18)
        .background(WorkspaceColor.graphite.color, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Workspace.anonymousName)
        .help(Workspace.anonymousName)
    }

    private var label: Label<Text, Image> {
        Label(Workspace.anonymousName, systemImage: Workspace.anonymousSymbol)
    }
}

/// Holds the fingerprint indicator just before the security button: it fades in over 0.2s when it first shows for
/// the shown tab's document (none under Reduce Motion), and goes at once.
private struct FingerprintSlot: View {
    let pane: BrowserPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = pane.selectedFingerprint
        ZStack {
            if let state {
                FingerprintIndicator(
                    site: state.site, isOff: state.isOff, isAnonymous: pane.model.isAnonymous, open: pane.openProtection)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(reduceMotion ? nil : .easeIn(duration: 0.2), value: state != nil)
    }
}

/// The page read a fingerprint (quiet, protected) or protection is off for its site (orange, the one loud state);
/// a click opens the protection page for that site (D5). Never a prompt.
private struct FingerprintIndicator: View {
    let site: String
    let isOff: Bool
    /// Anonymous keeps a key and exceptions per tab, so the texts speak of the tab.
    let isAnonymous: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: LodgePage.protection.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOff ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch (isOff, isAnonymous) {
        case (true, false): String(localized: "Fingerprint protection is off for \(site) in this workspace.")
        case (true, true): String(localized: "Fingerprint protection is off for \(site) in this tab.")
        case (false, false): String(localized: "\(site) read this page's fingerprint. Lodge gave it this workspace's own.")
        case (false, true): String(localized: "\(site) read this page's fingerprint. Lodge gave it this tab's own.")
        }
    }
}

/// The live page's security at the address bar's end; a click shows its origin and what the icon means.
private struct SiteSecurityButton: View {
    let pane: BrowserPane
    @State private var isShowingInfo = false

    private var url: URL? { pane.selected?.url }
    private var security: SiteSecurity { pane.selectedSecurity }

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
