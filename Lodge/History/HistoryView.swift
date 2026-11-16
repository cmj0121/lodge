import AppKit
import LodgeKit
import SwiftUI

/// History, drawn in its tab's page card at `lodge://history`: every visit of the workspace by day, newest first,
/// under a search field and Clear All History. Every History tab shows the one app-wide model.
struct HistoryView: View {
    @Bindable var model: HistoryModel
    @State private var selection: HistoryVisit.ID?
    /// This page among the History pages the model counts as showing.
    @State private var viewer = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // Nothing to search or clear where nothing is kept.
            if model.state != .notKept {
                header
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.pageAppeared(viewer) }
        .onDisappear { model.pageDisappeared(viewer) }
        .alert("History was cleared", isPresented: $model.clearLeftData) {
            Button("OK") {}
        } message: {
            Text("Some data will be removed when Lodge closes.")
        }
    }

    /// The search field and Clear All History, in place of the toolbar a browser window does not have.
    private var header: some View {
        HStack(spacing: 12) {
            HistorySearchField(text: $model.query)
                .frame(maxWidth: 360)
                .disabled(model.state != .ready)
            Spacer(minLength: 0)
            Button("Clear All History…") { HistoryPrompts.clearAll(model: model) }
                .help("Clear All History")
                .disabled(!model.canClearAll)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            spinner
        case .unavailable:
            ContentUnavailableView("History is unavailable.", systemImage: "clock")
        case .notKept:
            ContentUnavailableView(
                "History Is Not Kept", systemImage: "clock",
                description: Text("Pages you visit in this workspace are not saved."))
        case .ready where model.isSearching:
            searchContent
        case .ready:
            pagesContent
        }
    }

    /// While searching, only the search's own state shows: never the first page's.
    @ViewBuilder
    private var searchContent: some View {
        if model.searchFailed {
            failed
        } else if model.days.isEmpty {
            if model.isSearchPending { spinner } else { ContentUnavailableView.search(text: model.query) }
        } else {
            list
        }
    }

    @ViewBuilder
    private var pagesContent: some View {
        if model.loadFailed {
            failed
        } else if !model.hasFirstPage {
            spinner
        } else if model.days.isEmpty && !model.hasMore {
            ContentUnavailableView(
                "No History", systemImage: "clock", description: Text("Pages you visit appear here."))
        } else {
            list
        }
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A read failed: the store is there, so trying again may work.
    private var failed: some View {
        ContentUnavailableView {
            Label("History is unavailable.", systemImage: "clock")
        } actions: {
            Button("Try Again", action: model.retry)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.days) { day in
                Section(day.title) {
                    ForEach(day.visits) { visit in
                        HistoryRow(visit: visit)
                            .onAppear { if visit.id == model.loadMoreTrigger { model.loadMore() } }
                    }
                }
            }
            if model.hasMore {
                Group {
                    if model.pageLoadFailed {
                        Button("Try Again", action: model.loadMore)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .onAppear(perform: model.loadMore)
                    }
                }
                .frame(maxWidth: .infinity)
                .selectionDisabled()
            }
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: HistoryVisit.ID.self) { ids in
            if let visit = ids.first.flatMap(model.visit) {
                Button("Open") { model.open(visit) }
                Button("Copy Link") { model.copyLink(visit) }
            }
        } primaryAction: { ids in
            if let visit = ids.first.flatMap(model.visit) { model.open(visit) }
        }
    }
}

/// The page's search field: a magnifying glass, the text, and a button that empties it.
private struct HistorySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search History", text: $text)
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator, lineWidth: 0.5) }
    }
}

/// One visit: its site's letter, the title, the host and the time of day.
private struct HistoryRow: View {
    let visit: HistoryVisit

    private var host: String { visit.url.host() ?? visit.url.absoluteString }
    private var title: String { visit.title.isEmpty ? visit.url.absoluteString : visit.title }
    private var time: String { visit.visitedAt.formatted(date: .omitted, time: .shortened) }

    /// The host's first letter, skipping a leading "www.".
    private var letter: String {
        let name = host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
        return name.first.map { String($0).uppercased() } ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            LetterIcon(letter: letter, size: 16, isOnTile: false)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(host)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(time)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(host), \(time)"))
        .accessibilityHint("Opens the page in a new tab")
    }
}

/// The question Clear All History asks before it empties the store.
@MainActor
enum HistoryPrompts {
    static func clearAll(model: HistoryModel) {
        guard model.canClearAll else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear all history?")
        alert.informativeText = String(
            localized: "This removes every page from this workspace's history. Open tabs keep their back and forward pages.")
        alert.addButton(withTitle: String(localized: "Clear All History")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { model.clearAll() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
