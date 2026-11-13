import Foundation
import Testing

@testable import LodgeKit

@Suite struct HistoryPagesTests {
    /// Visit `id` at second `id`, so a larger id is newer.
    private func visit(_ id: Int64, title: String = "") -> HistoryVisit {
        HistoryVisit(
            id: id, url: URL(string: "https://\(id).example/")!, title: title,
            visitedAt: Date(timeIntervalSince1970: TimeInterval(id)))
    }

    private func visits(_ ids: ClosedRange<Int64>) -> [HistoryVisit] { ids.reversed().map { visit($0) } }

    private func loaded(_ ids: ClosedRange<Int64>, limit: Int) -> HistoryPages {
        var pages = HistoryPages()
        var all = visits(ids)
        while !pages.isComplete {
            let cursor = pages.oldest
            let page = Array(all.prefix(limit))
            all.removeFirst(page.count)
            pages.append(page, after: cursor, limit: limit)
        }
        return pages
    }

    @Test func appendsPagesUntilOneComesBackShort() {
        var pages = HistoryPages()
        pages.append(visits(8...10), after: nil, limit: 3)
        #expect(!pages.isComplete)
        pages.append(visits(5...7), after: visit(8), limit: 3)
        pages.append(visits(4...4), after: visit(5), limit: 3)
        #expect(pages.visits.map(\.id) == Array((4...10).reversed()))
        #expect(pages.isComplete)
    }

    @Test func dropsAPageWhoseCursorIsStaleAndSaysSo() {
        var pages = HistoryPages()
        let first = pages.append(visits(8...10), after: nil, limit: 3)
        let stale = pages.append(visits(1...3), after: visit(4), limit: 3)
        #expect(first)
        #expect(!stale)
        #expect(pages.visits.map(\.id) == [10, 9, 8])
        #expect(!pages.isComplete)
        let next = pages.append(visits(5...7), after: visit(8), limit: 3)
        #expect(next)
    }

    @Test func keepingTheFirstPageDropsOlderPagesAndLetsThemLoadAgain() {
        var pages = loaded(1...5, limit: 3)
        pages.keepFirstPage(limit: 3)
        #expect(pages.visits.map(\.id) == [5, 4, 3])
        #expect(!pages.isComplete)
        let appended = pages.append(visits(1...2), after: visit(3), limit: 3)
        #expect(appended)
        #expect(pages.visits.map(\.id) == Array((1...5).reversed()))
        #expect(pages.isComplete)
    }

    @Test func keepingTheFirstPageOfAShortHistoryChangesNothing() {
        var pages = loaded(1...2, limit: 3)
        pages.keepFirstPage(limit: 3)
        #expect(pages.visits.map(\.id) == [2, 1])
        #expect(pages.isComplete)
    }

    @Test func refreshPutsNewVisitsOnTopAndKeepsOlderPages() {
        var pages = HistoryPages()
        pages.append(visits(8...10), after: nil, limit: 3)
        pages.append(visits(5...7), after: visit(8), limit: 3)
        pages.refresh(firstPage: visits(10...12), limit: 3)
        #expect(pages.visits.map(\.id) == Array((5...12).reversed()))
        #expect(!pages.isComplete)
    }

    @Test func refreshTakesNewTitlesAndMovedVisits() {
        var pages = HistoryPages()
        pages.append(visits(8...10), after: nil, limit: 3)
        pages.append(visits(5...7), after: visit(8), limit: 3)
        // Visit 9 was revisited (coalesced): it moves to the top with its new time.
        let moved = HistoryVisit(id: 9, url: visit(9).url, title: "Again", visitedAt: Date(timeIntervalSince1970: 11))
        pages.refresh(firstPage: [moved, visit(10, title: "Ten"), visit(8)], limit: 3)
        #expect(pages.visits.map(\.id) == [9, 10, 8, 7, 6, 5])
        #expect(pages.visits.prefix(2).map(\.title) == ["Again", "Ten"])
    }

    @Test func refreshKeepsTheEndWhenEverythingIsLoaded() {
        var pages = loaded(1...5, limit: 3)
        pages.refresh(firstPage: visits(4...6), limit: 3)
        #expect(pages.visits.map(\.id) == Array((1...6).reversed()))
        #expect(pages.isComplete)
    }

    @Test func aShortFirstPageIsTheWholeHistory() {
        var pages = loaded(1...5, limit: 3)
        pages.refresh(firstPage: visits(6...6), limit: 3)
        #expect(pages.visits.map(\.id) == [6])
        #expect(pages.isComplete)
    }

    @Test func clearedHistoryEmptiesThePages() {
        var pages = loaded(1...5, limit: 3)
        pages.refresh(firstPage: [], limit: 3)
        #expect(pages.visits.isEmpty)
        #expect(pages.isComplete)
        #expect(pages.oldest == nil)
    }

    @Test func moreThanAPageOfNewVisitsDropsTheOlderPagesSoNoGapShows() {
        var pages = loaded(1...5, limit: 3)
        pages.refresh(firstPage: visits(10...12), limit: 3)
        #expect(pages.visits.map(\.id) == [12, 11, 10])
        #expect(!pages.isComplete)
    }
}
