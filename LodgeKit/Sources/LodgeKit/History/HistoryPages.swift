import Foundation

/// The visits the History window has loaded, newest first: pages appended as it scrolls, and the first page
/// merged back in when the store changes, so a new visit shows without dropping the pages below it.
public struct HistoryPages: Equatable, Sendable {
    public private(set) var visits: [HistoryVisit] = []
    /// Whether the oldest visit in the store is loaded, so there is no page left to ask for.
    public private(set) var isComplete = false

    public init() {}

    /// The cursor of the next page.
    public var oldest: HistoryVisit? { visits.last }

    /// Appends `page`, fetched with `page(after: cursor, limit: limit)`. A page whose cursor is no longer the
    /// oldest visit (a refresh landed while it loaded) is dropped; returns false then, so the caller can ask again.
    @discardableResult
    public mutating func append(_ page: [HistoryVisit], after cursor: HistoryVisit?, limit: Int) -> Bool {
        guard cursor == oldest else { return false }
        let loaded = Set(visits.map(\.id))
        visits += page.filter { !loaded.contains($0.id) }
        isComplete = page.count < limit
        return true
    }

    /// Keeps only the newest `limit` visits, as when the window closes, so the older pages load again on scroll.
    public mutating func keepFirstPage(limit: Int) {
        guard visits.count > limit else { return }
        visits.removeLast(visits.count - limit)
        isComplete = false
    }

    /// Replaces the visits from the newest down to the oldest of `firstPage`, fetched with
    /// `page(after: nil, limit: limit)`, keeping the loaded visits older than it. When `firstPage` does not reach
    /// the newest loaded visit, more than a page arrived and the older visits are dropped, so no gap shows.
    public mutating func refresh(firstPage: [HistoryVisit], limit: Int) {
        guard let cutoff = firstPage.last, firstPage.count == limit else {
            visits = firstPage
            isComplete = true
            return
        }
        guard let newest = visits.first, !Self.isOlder(newest, than: cutoff) else {
            visits = firstPage
            isComplete = false
            return
        }
        let fresh = Set(firstPage.map(\.id))
        let tail = visits.filter { Self.isOlder($0, than: cutoff) && !fresh.contains($0.id) }
        visits = firstPage + tail
        isComplete = isComplete && !tail.isEmpty
    }

    /// The store's page order: `(visitedAt, id)` descending.
    private static func isOlder(_ visit: HistoryVisit, than other: HistoryVisit) -> Bool {
        (visit.visitedAt, visit.id) < (other.visitedAt, other.id)
    }
}
