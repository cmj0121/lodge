import AppKit
import LodgeKit
import Observation
import os

/// State and actions of the History window: the shown workspace's visits loaded page by page, grouped by day, and
/// the search.
/// While the window is closed nothing loads: changes only mark the list dirty, and it refreshes when shown again.
@MainActor
@Observable
final class HistoryModel {
    enum State: Equatable {
        /// The history file is still opening.
        case loading
        case ready
        /// The history file could not open, so nothing is recorded this run.
        case unavailable
        /// The workspace keeps no history.
        case notKept
    }

    static let pageSize = 200
    /// Searches have no cursor, so they show up to this many matches.
    static let searchLimit = 500
    static let searchDelay = Duration.milliseconds(200)

    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    private(set) var state = State.loading
    /// Whether the first page has been shown; until then the window shows a spinner.
    private(set) var hasFirstPage = false
    /// Whether the last refresh could not read the store; the window says so and offers to try again.
    private(set) var loadFailed = false
    /// Whether the search for the current query could not read the store, so its matches are not shown.
    private(set) var searchFailed = false
    /// Whether a search for the current query is waiting out the debounce or running.
    private(set) var isSearchPending = false
    /// Whether the last next-page read failed; the end of the list offers to try again instead of loading.
    private(set) var pageLoadFailed = false
    /// Whether the last Clear All deleted the visits but left some old data on disk until Lodge closes; the
    /// window says so.
    var clearLeftData = false
    /// The shown visits by day: the search's matches while there is a query, else the loaded pages.
    private(set) var days: [HistoryDay] = []
    /// The visit a row near the end of the loaded pages, whose appearing loads the next page before the end shows.
    private(set) var loadMoreTrigger: Int64?
    /// The search text; a change runs the search after `searchDelay`, and an empty one shows the pages again.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    /// Opens a visit's page in a new tab of the key window's workspace.
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var store: (any HistorySource)?
    @ObservationIgnored private var pages = HistoryPages() {
        didSet { if !isSearching { regroup() } }
    }
    @ObservationIgnored private var matches: [HistoryVisit] = [] {
        didSet { if isSearching { regroup() } }
    }
    @ObservationIgnored private var isVisible = false
    /// Set when the store changed while the window was closed.
    @ObservationIgnored private var isDirty = true
    @ObservationIgnored private var isLoadingPage = false
    /// Each refresh replaces the earlier ones; a clear voids them all.
    @ObservationIgnored private var refreshes = LatestOnly()
    /// Page loads join the current generation; a clear or the window closing voids them.
    @ObservationIgnored private var pageLoads = LatestOnly()
    /// Each search replaces the earlier ones; a new query or a clear voids them all.
    @ObservationIgnored private var searches = LatestOnly()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Each shown store replaces the earlier ones, so what a refresh of the one before finds is not shown.
    @ObservationIgnored private var shownStores = LatestOnly()
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// Following of earlier stores, cancelled but maybe not yet ended.
    @ObservationIgnored private var stoppedChanges: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var stoppedCount: UInt64 = 0

    init(open: @escaping @MainActor (URL) -> Void) {
        openURL = open
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// Whether scrolling to the end can load another page.
    var hasMore: Bool { state == .ready && hasFirstPage && !isSearching && !pages.isComplete }

    var canClearAll: Bool { state == .ready }

    // MARK: Store

    /// Shows another workspace's history (nil while its store opens, or when it has none): stops following the
    /// previous store, voids its loads and searches still running and empties the list, then follows `store`'s
    /// changes, loading them while the window shows. The query stays and runs again on the new store.
    func show(_ store: (any HistorySource)?, state: State) {
        if let changesTask {
            changesTask.cancel()
            stoppedCount &+= 1
            let key = stoppedCount
            stoppedChanges[key] = changesTask
            Task {
                await changesTask.value
                stoppedChanges[key] = nil
            }
        }
        changesTask = nil
        searchTask?.cancel()
        shownStores.invalidate()
        refreshes.invalidate()
        pageLoads.invalidate()
        searches.invalidate()
        self.store = store
        self.state = state
        isDirty = true
        if hasFirstPage { hasFirstPage = false }
        if loadFailed { loadFailed = false }
        if searchFailed { searchFailed = false }
        if pageLoadFailed { pageLoadFailed = false }
        if clearLeftData { clearLeftData = false }
        isSearchPending = isSearching && store != nil
        matches = []
        pages.refresh(firstPage: [], limit: Self.pageSize)
        guard let store else { return }
        changesTask = Task { [weak self] in
            for await _ in store.changes() {
                guard let self else { return }
                if self.isVisible { await self.refresh() } else { self.isDirty = true }
            }
        }
    }

    /// Waits until no store shown before stops being followed, so its file can close.
    func stoppedFollowing() async {
        for task in stoppedChanges.values { await task.value }
    }

    // MARK: Window

    /// The window appeared: brings a list that went stale while it was closed up to date.
    func windowAppeared() {
        isVisible = true
        regroup()
        if isDirty { Task { await refresh() } }
    }

    /// The window closed: keeps only the first page, so a long scroll's pages are not held while nobody looks.
    func windowDisappeared() {
        isVisible = false
        pageLoads.invalidate()
        pages.keepFirstPage(limit: Self.pageSize)
        days = []
    }

    /// Merges the newest page into the loaded ones, and runs the search again so its matches stay current. A failed
    /// read leaves the list dirty, so showing the window again retries it.
    private func refresh() async {
        guard let store else { return }
        isDirty = false
        let shown = shownStores.ticket
        let ticket = refreshes.begin()
        do {
            let first = try await store.page(after: nil, limit: Self.pageSize)
            guard refreshes.accepts(ticket), !Task.isCancelled else { return }
            pages.refresh(firstPage: first, limit: Self.pageSize)
            if !hasFirstPage { hasFirstPage = true }
            if loadFailed { loadFailed = false }
            if pageLoadFailed { pageLoadFailed = false }
        } catch {
            Self.logger.error("History page failed: \(error.localizedDescription, privacy: .public)")
            isDirty = true
            if refreshes.accepts(ticket), !loadFailed { loadFailed = true }
        }
        if isSearching, shownStores.accepts(shown) { await search(trimmedQuery, in: store) }
    }

    /// "Try Again" after a failed read: reloads the first page, which runs the search again too.
    func retry() {
        Task { await refresh() }
    }

    /// Loads the page after the oldest loaded visit, one at a time; also "Try Again" after a failed page. A page
    /// dropped because a refresh moved the oldest visit while it loaded, or voided, is asked for again, so the
    /// spinner at the end of the list never waits on nothing.
    func loadMore() {
        guard let store, hasMore, !isLoadingPage else { return }
        isLoadingPage = true
        if pageLoadFailed { pageLoadFailed = false }
        let cursor = pages.oldest
        let ticket = pageLoads.ticket
        Task {
            var loadAgain = false
            do {
                let page = try await store.page(after: cursor, limit: Self.pageSize)
                loadAgain = !pageLoads.accepts(ticket) || !pages.append(page, after: cursor, limit: Self.pageSize)
            } catch {
                Self.logger.error("History page failed: \(error.localizedDescription, privacy: .public)")
                if pageLoads.accepts(ticket) { pageLoadFailed = true } else { loadAgain = true }
            }
            isLoadingPage = false
            // A voided load (the window closed and opened again meanwhile) may have kept the reopened list's own
            // request out; after a clear, `hasMore` is false and this does nothing.
            if loadAgain, isVisible { loadMore() }
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searches.invalidate()
        if searchFailed { searchFailed = false }
        isSearchPending = isSearching
        guard isSearching else {
            matches = []
            regroup()
            return
        }
        guard let store else { return }
        let text = trimmedQuery
        searchTask = Task {
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            await search(text, in: store)
        }
    }

    /// Shows the matches for `text` unless a newer search, a new query or a clear came while it ran.
    private func search(_ text: String, in store: any HistorySource) async {
        let ticket = searches.begin()
        do {
            let found = try await store.search(text, limit: Self.searchLimit)
            guard searches.accepts(ticket), !Task.isCancelled else { return }
            if searchFailed { searchFailed = false }
            isSearchPending = false
            matches = found
        } catch {
            Self.logger.error("History search failed: \(error.localizedDescription, privacy: .public)")
            guard searches.accepts(ticket), !Task.isCancelled else { return }
            isSearchPending = false
            matches = []
            searchFailed = true
        }
    }

    private func regroup() {
        guard isVisible else { return }
        let visits = isSearching ? matches : pages.visits
        days = HistoryDay.group(visits, calendar: .current, now: .now)
        let trigger = isSearching ? nil : visits.dropLast(Self.pageSize / 4).last?.id ?? visits.last?.id
        if loadMoreTrigger != trigger { loadMoreTrigger = trigger }
    }

    // MARK: Actions

    /// The shown visit with `id`.
    func visit(_ id: HistoryVisit.ID) -> HistoryVisit? {
        days.lazy.flatMap(\.visits).first { $0.id == id }
    }

    /// Opens the visit's page in a new tab of the key window's workspace; the view has already brought the browser
    /// window up.
    func open(_ visit: HistoryVisit) {
        openURL(visit.url)
    }

    func copyLink(_ visit: HistoryVisit) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([visit.url as NSURL])
        pasteboard.setString(visit.url.absoluteString, forType: .string)
    }

    /// Empties the shown workspace's list at once, voiding every load and search still running, then the store; the
    /// store's change refreshes the list again. Works with the window closed.
    func clearAll() {
        guard let store else { return }
        searchTask?.cancel()
        refreshes.invalidate()
        pageLoads.invalidate()
        searches.invalidate()
        if searchFailed { searchFailed = false }
        isSearchPending = false
        if pageLoadFailed { pageLoadFailed = false }
        if loadFailed { loadFailed = false }
        // The list is known empty now, so no spinner waits on the refresh the store's change brings.
        if !hasFirstPage { hasFirstPage = true }
        matches = []
        pages.refresh(firstPage: [], limit: Self.pageSize)
        Task {
            do {
                try await store.clearAll()
            } catch HistoryStore.ClearError.checkpointBusy {
                clearLeftData = true
            } catch {
                Self.logger.error("Clear All History failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
