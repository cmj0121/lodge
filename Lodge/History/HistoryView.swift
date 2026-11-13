import AppKit
import LodgeKit
import SwiftUI

/// The History window: every visit by day, newest first, with a search field and Clear All in the toolbar.
struct HistoryView: View {
    @Bindable var model: HistoryModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: HistoryVisit.ID?

    var body: some View {
        content
            .frame(minWidth: 420, minHeight: 320)
            .onAppear(perform: model.windowAppeared)
            .onDisappear(perform: model.windowDisappeared)
            .searchable(text: $model.query, placement: .toolbar, prompt: "Search History")
            .alert("History was cleared", isPresented: $model.clearLeftData) {
                Button("OK") {}
            } message: {
                Text("Some data will be removed when Lodge closes.")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear All History…", systemImage: "trash") { HistoryPrompts.clearAll(model: model) }
                        .help("Clear All History")
                        .disabled(!model.canClearAll)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            spinner
        case .unavailable:
            ContentUnavailableView("History is unavailable.", systemImage: "clock")
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
        .contextMenu(forSelectionType: HistoryVisit.ID.self) { ids in
            if let visit = ids.first.flatMap(model.visit) {
                Button("Open") { open(visit) }
                Button("Copy Link") { model.copyLink(visit) }
            }
        } primaryAction: { ids in
            if let visit = ids.first.flatMap(model.visit) { open(visit) }
        }
    }

    /// D6: brings the browser window back (reopening it when closed) and opens the page in a new tab there.
    private func open(_ visit: HistoryVisit) {
        openWindow(id: "browser")
        NSApp.activate()
        model.open(visit)
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
        .accessibilityLabel("\(title), \(host), \(time)")
        .accessibilityHint("Opens the page in a new tab")
    }
}

/// The question Clear All History asks before it empties the store.
@MainActor
enum HistoryPrompts {
    static func clearAll(model: HistoryModel) {
        guard model.canClearAll else { return }
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "This removes every page from your history. Open tabs keep their back and forward pages."
        alert.addButton(withTitle: "Clear All History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
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
