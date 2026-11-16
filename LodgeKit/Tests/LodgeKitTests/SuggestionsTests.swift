import Foundation
import Synchronization
import Testing

@testable import LodgeKit

@Suite struct SuggestionRankerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func page(
        _ address: String, _ title: String = "", lastUsed: Date? = nil, useCount: Int = 0, tab: TabID? = nil
    ) -> SuggestionCandidate {
        SuggestionCandidate(url: URL(string: address)!, title: title, lastUsed: lastUsed, useCount: useCount, tab: tab)
    }

    private func rank(
        _ words: String, engine: SearchEngine = .duckDuckGo, openTabs: [SuggestionCandidate] = [],
        bookmarks: [SuggestionCandidate] = [], history: [SuggestionCandidate] = []
    ) -> [Suggestion] {
        SuggestionRanker.rank(words: words, engine: engine, openTabs: openTabs, bookmarks: bookmarks, history: history)
    }

    private func addresses(_ rows: [Suggestion]) -> [String?] { rows.map { $0.url?.absoluteString } }

    @Test func blankWordsGiveNoRows() {
        let pages = [page("https://swift.org/")]
        #expect(rank("", openTabs: pages, bookmarks: pages, history: pages).isEmpty)
        #expect(rank("  \n ", openTabs: pages, bookmarks: pages, history: pages).isEmpty)
    }

    @Test func theSearchRowComesFirstWithTheGivenEngine() throws {
        let kagi = try #require(SearchEngine.builtIns.first { $0.id == "kagi" })
        let rows = rank(" swift ", engine: kagi, history: [page("https://swift.org/", "Swift")])
        #expect(rows.first == Suggestion(kind: .search, title: "Search swift with Kagi", url: nil))
        #expect(rows.count == 2)
        #expect(rank("nothing matches", engine: kagi).map(\.kind) == [.search])
    }

    @Test func groupsComeInOrderOpenTabsBookmarksHistory() {
        let tab = TabID()
        let rows = rank(
            "swift", openTabs: [page("https://swift.org/tab", "Swift", tab: tab)],
            bookmarks: [page("https://swift.org/bookmark", "Swift")],
            history: [page("https://swift.org/history", "Swift", lastUsed: start, useCount: 9)])
        #expect(rows.map(\.kind) == [.search, .openTab(tab), .bookmark, .history])
        #expect(addresses(rows) == [
            nil, "https://swift.org/tab", "https://swift.org/bookmark", "https://swift.org/history",
        ])
    }

    @Test func atMostEightRows() {
        let many = (0..<20).map { page("https://swift.org/\($0)", "Swift \($0)") }
        let tabs = many.map { page($0.url.absoluteString, $0.title, tab: TabID()) }
        let rows = rank("swift", openTabs: tabs, history: many)
        #expect(rows.count == SuggestionRanker.limit)
        #expect(SuggestionRanker.limit == 8)
        #expect(rows.dropFirst().allSatisfy { if case .openTab = $0.kind { true } else { false } })
    }

    @Test func aURLShowsOnceInItsEarliestGroup() {
        let tab = TabID()
        let rows = rank(
            "swift", openTabs: [page("https://swift.org/", "Swift", tab: tab)],
            bookmarks: [page("https://swift.org/", "Swift"), page("https://swift.org/blog", "Blog")],
            history: [page("https://swift.org/blog", "Blog"), page("https://swift.org/blog", "Blog again")])
        #expect(rows.map(\.kind) == [.search, .openTab(tab), .bookmark])
        #expect(addresses(rows) == [nil, "https://swift.org/", "https://swift.org/blog"])
    }

    @Test func matchQualityOrdersAGroup() {
        let rows = rank(
            "swi",
            history: [
                page("https://example.com/swift", "A page", lastUsed: start + 30),
                page("https://news.example/", "Learn Swift", lastUsed: start + 20),
                page("https://www.swiss.example/", "Mountains", lastUsed: start),
                page("https://nothing.example/", "Unrelated", lastUsed: start + 40),
            ])
        #expect(addresses(rows) == [
            nil, "https://www.swiss.example/", "https://news.example/", "https://example.com/swift",
        ])
    }

    @Test func recencyThenFrequencyBreakEqualMatches() {
        let rows = rank(
            "swift",
            history: [
                page("https://swift.org/old", "Swift", lastUsed: start, useCount: 50),
                page("https://swift.org/rare", "Swift", lastUsed: start + 60, useCount: 1),
                page("https://swift.org/often", "Swift", lastUsed: start + 60, useCount: 7),
                page("https://swift.org/never", "Swift"),
            ])
        #expect(addresses(rows) == [
            nil, "https://swift.org/often", "https://swift.org/rare", "https://swift.org/old",
            "https://swift.org/never",
        ])
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let bookmarks = [page("https://menu.example/", "Le Café"), page("https://x.example/", "Tea")]
        let rows = rank("CAFE", bookmarks: bookmarks)
        #expect(addresses(rows) == [nil, "https://menu.example/"])
        #expect(rank("café", history: [page("https://cafe.example/")]).count == 2)
        #expect(rank("台北", history: [page("https://w.example/", "台北天氣")]).count == 2)
    }

    @Test func aTitlelessRowShowsItsAddress() {
        #expect(rank("swift", history: [page("https://swift.org/")]).last?.title == "https://swift.org/")
    }

    @Test func historyVisitsFoldPerURL() {
        let a = URL(string: "https://a.example/")!
        let b = URL(string: "https://b.example/")!
        let visits = [
            HistoryVisit(id: 4, url: b, title: "B", visitedAt: start + 30),
            HistoryVisit(id: 3, url: a, title: "", visitedAt: start + 20),
            HistoryVisit(id: 2, url: a, title: "A new", visitedAt: start + 10),
            HistoryVisit(id: 1, url: a, title: "A old", visitedAt: start),
        ]
        #expect(SuggestionRanker.candidates(from: visits) == [
            SuggestionCandidate(url: b, title: "B", lastUsed: start + 30, useCount: 1),
            SuggestionCandidate(url: a, title: "A new", lastUsed: start + 20, useCount: 3),
        ])
        #expect(SuggestionRanker.candidates(from: []).isEmpty)
    }

    @Test func openTabCandidatesLeaveOutTheShownTabAndBlankTabs() {
        let shown = BrowserTab(url: URL(string: "https://shown.example/"))
        let other = BrowserTab(url: URL(string: "https://other.example/"), title: "Other")
        let blank = BrowserTab()
        #expect(SuggestionCandidate.openTabs([shown, other, blank], except: shown.id) == [
            SuggestionCandidate(url: URL(string: "https://other.example/")!, title: "Other", tab: other.id)
        ])
    }

    private func complete(_ typed: String, _ candidates: [SuggestionCandidate]) -> String? {
        SuggestionRanker.completion(for: typed, among: candidates)
    }

    @Test func completesToAHostTheTypedTextStarts() {
        let pages = [page("https://github.com/apple/swift")]
        #expect(complete("git", pages) == "github.com")
        #expect(complete("g", pages) == "github.com")
        #expect(complete("github.com", pages) == nil)
    }

    @Test func completionSkipsWWWUnlessTyped() {
        let pages = [page("https://www.swift.org/blog/")]
        #expect(complete("sw", pages) == "swift.org")
        #expect(complete("www.sw", pages) == "www.swift.org")
        #expect(complete("ww", pages) == nil)
    }

    @Test func pastTheHostCompletesTheHostAndPath() {
        let pages = [page("https://github.com/apple/swift"), page("https://github.com/")]
        #expect(complete("github.com/a", pages) == "github.com/apple/swift")
        #expect(complete("github.com/", pages) == "github.com/apple/swift")
        #expect(complete("github.com/apple/swift", pages) == nil)
        #expect(complete("github.com/x", pages) == nil)
    }

    @Test func theBestRankedCandidateCompletes() {
        let older = page("https://gist.github.com/", lastUsed: start, useCount: 9)
        let newer = page("https://github.com/", lastUsed: start + 60)
        let often = page("https://gitlab.com/", lastUsed: start + 60, useCount: 3)
        #expect(complete("gi", [older, newer]) == "github.com")
        #expect(complete("gi", [older, newer, often]) == "gitlab.com")
        #expect(complete("gi", [page("https://gitea.example/"), page("https://gitlab.com/")]) == "gitea.example")
        // A host wins over a host and path, whatever their recency.
        let path = page("https://go.dev/doc", lastUsed: start + 600)
        #expect(complete("go.dev", [path, page("https://go.dev.example/", lastUsed: start)]) == "go.dev.example")
    }

    @Test func completionKeepsTheTypedCase() {
        let pages = [page("https://GitHub.com/Apple/Swift")]
        #expect(complete("GIT", pages) == "GIThub.com")
        #expect(complete("github.com/apple/s", pages) == "github.com/apple/swift")
    }

    @Test func noCompletionForSpacesBlankOrNoMatch() {
        let pages = [page("https://github.com/"), page("lodge://history"), page("file:///Users/me/notes.txt")]
        #expect(complete("", pages) == nil)
        #expect(complete("git hub", pages) == nil)
        #expect(complete("git ", pages) == nil)
        #expect(complete("swift", pages) == nil)
        #expect(complete("his", pages) == nil)
        #expect(complete("git", []) == nil)
    }
}

/// A history stand-in that answers `search` from fixed visits and counts the reads.
private final class FixedHistory: HistorySource {
    let visits: [HistoryVisit]
    private let reads = Mutex(0)

    init(_ visits: [HistoryVisit]) { self.visits = visits }

    var readCount: Int { reads.withLock { $0 } }

    func page(after cursor: HistoryVisit?, limit: Int) async throws -> [HistoryVisit] { [] }

    func search(_ query: String, limit: Int) async throws -> [HistoryVisit] {
        reads.withLock { $0 += 1 }
        return visits.filter {
            $0.url.absoluteString.localizedStandardContains(query) || $0.title.localizedStandardContains(query)
        }
    }

    func clearAll() async throws {}

    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Counts every request any URL session started while it was registered, and answers each with an error.
private final class CountingProtocol: URLProtocol {
    static let count = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool {
        count.withLock { $0 += 1 }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }

    override func stopLoading() {}
}

@MainActor @Suite struct SuggestionModelTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let tab = TabID()

    private func model(
        history: (any HistorySource)?, openTabs: [SuggestionCandidate] = [], bookmarks: [SuggestionCandidate] = [],
        engine: SearchEngine = .duckDuckGo
    ) -> SuggestionModel {
        SuggestionModel(history: history, local: { (openTabs, bookmarks) }, engine: { engine }, debounce: .zero)
    }

    private var swiftTab: SuggestionCandidate {
        SuggestionCandidate(url: URL(string: "https://swift.org/")!, title: "Swift", tab: tab)
    }

    private var swiftBookmark: SuggestionCandidate {
        SuggestionCandidate(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog")
    }

    private var swiftVisit: HistoryVisit {
        HistoryVisit(id: 1, url: URL(string: "https://forums.swift.org/")!, title: "Swift Forums", visitedAt: start)
    }

    @Test func localRowsShowAtOnceAndHistoryFollows() async {
        let suggestions = model(history: FixedHistory([swiftVisit]), openTabs: [swiftTab], bookmarks: [swiftBookmark])
        suggestions.update("swift")
        #expect(suggestions.rows.map(\.kind) == [.search, .openTab(tab), .bookmark])
        await suggestions.historyRead?.value
        #expect(suggestions.rows.map(\.kind) == [.search, .openTab(tab), .bookmark, .history])
        #expect(suggestions.words == "swift")
    }

    @Test func theSearchRowUsesTheEngineAtTheMomentOfTyping() throws {
        let google = try #require(SearchEngine.builtIns.first { $0.id == "google" })
        let suggestions = model(history: nil, engine: google)
        suggestions.update("weather")
        #expect(suggestions.rows == [Suggestion(kind: .search, title: "Search weather with Google", url: nil)])
    }

    @Test func anonymousSuggestsOnlyItsTabsBookmarksAndTheSearch() async {
        let suggestions = model(history: nil, openTabs: [swiftTab], bookmarks: [swiftBookmark])
        suggestions.update("swift")
        #expect(suggestions.historyRead == nil)
        #expect(suggestions.rows.map(\.kind) == [.search, .openTab(tab), .bookmark])
    }

    /// Each field's model reads only the sources it was given: another workspace's pages never show.
    @Test func onlyTheGivenWorkspaceSourcesShow() async {
        let mine = model(history: FixedHistory([swiftVisit]), bookmarks: [swiftBookmark])
        let other = model(
            history: FixedHistory([
                HistoryVisit(id: 9, url: URL(string: "https://swift.other/")!, title: "Swift", visitedAt: start)
            ]), openTabs: [swiftTab])
        mine.update("swift")
        other.update("swift")
        await mine.historyRead?.value
        await other.historyRead?.value
        #expect(mine.rows.compactMap(\.url?.absoluteString) == ["https://swift.org/blog", "https://forums.swift.org/"])
        #expect(other.rows.compactMap(\.url?.absoluteString) == ["https://swift.org/", "https://swift.other/"])
    }

    @Test func blankTextEmptiesTheListWithoutReadingHistory() async {
        let history = FixedHistory([swiftVisit])
        let suggestions = model(history: history, bookmarks: [swiftBookmark])
        suggestions.update("swift")
        await suggestions.historyRead?.value
        suggestions.update("   ")
        #expect(suggestions.rows.isEmpty)
        #expect(suggestions.historyRead == nil)
        #expect(history.readCount == 1)
    }

    @Test func aNewerUpdateDropsTheReadUnderWay() async {
        let history = FixedHistory([swiftVisit])
        let suggestions = SuggestionModel(
            history: history, local: { ([], []) }, engine: { .duckDuckGo }, debounce: .seconds(60))
        suggestions.update("swi")
        let first = suggestions.historyRead
        suggestions.update("swift")
        await first?.value
        #expect(history.readCount == 0)
        suggestions.dismiss()
        #expect(suggestions.rows.isEmpty)
        #expect(suggestions.historyRead == nil)
    }

    @Test func upAndDownMoveTheHighlight() {
        let suggestions = model(history: nil, openTabs: [swiftTab], bookmarks: [swiftBookmark])
        suggestions.moveDown()
        #expect(suggestions.highlighted == nil)
        suggestions.update("swift")
        #expect(suggestions.highlighted == nil)
        suggestions.moveUp()
        #expect(suggestions.highlighted == nil)
        suggestions.moveDown()
        #expect(suggestions.highlighted == 0)
        suggestions.moveDown()
        suggestions.moveDown()
        suggestions.moveDown()
        #expect(suggestions.highlighted == 2)
        suggestions.moveUp()
        #expect(suggestions.highlighted == 1)
        suggestions.moveUp()
        suggestions.moveUp()
        #expect(suggestions.highlighted == nil)
    }

    @Test func typingClearsTheHighlightAndHistoryKeepsIt() async {
        let suggestions = model(history: FixedHistory([swiftVisit]), openTabs: [swiftTab])
        suggestions.update("swift")
        suggestions.moveDown()
        suggestions.moveDown()
        await suggestions.historyRead?.value
        #expect(suggestions.highlighted == 1)
        #expect(suggestions.rows[1].kind == .openTab(tab))
        suggestions.update("swift ")
        #expect(suggestions.highlighted == nil)
    }

    @Test func dismissClosesTheListAndKeepsTheWords() {
        let suggestions = model(history: nil, bookmarks: [swiftBookmark])
        suggestions.update("swift")
        suggestions.moveDown()
        suggestions.dismiss()
        #expect(suggestions.rows.isEmpty)
        #expect(suggestions.highlighted == nil)
        #expect(suggestions.words == "swift")
    }

    @Test func completionFollowsTheTypedTextAndHistoryOnceRead() async {
        let suggestions = model(history: FixedHistory([swiftVisit]), openTabs: [swiftTab])
        suggestions.update("sw")
        #expect(suggestions.completion == "swift.org")
        suggestions.update("fo")
        #expect(suggestions.completion == nil)
        await suggestions.historyRead?.value
        #expect(suggestions.completion == "forums.swift.org")
        suggestions.update("fo ")
        #expect(suggestions.completion == nil)
        suggestions.update("Fo")
        #expect(suggestions.completion == "Forums.swift.org")
        suggestions.dismiss()
        #expect(suggestions.completion == nil)
    }

    @Test func anonymousCompletesOnlyFromItsTabsAndBookmarks() {
        let suggestions = model(history: nil, openTabs: [swiftTab], bookmarks: [swiftBookmark])
        suggestions.update("swift.org/b")
        #expect(suggestions.completion == "swift.org/blog")
        suggestions.update("forums")
        #expect(suggestions.completion == nil)
        #expect(suggestions.historyRead == nil)
    }

    /// Typing reads only the history file and the given sources: no URL request starts while `update` runs.
    @Test func typingMakesNoNetworkRequest() async throws {
        let store = try HistoryStore.inMemory()
        _ = try await store.record(URL(string: "https://swift.org/documentation/")!, title: "Swift Docs", at: start)
        let suggestions = model(history: store, openTabs: [swiftTab], bookmarks: [swiftBookmark])
        URLProtocol.registerClass(CountingProtocol.self)
        defer { URLProtocol.unregisterClass(CountingProtocol.self) }
        CountingProtocol.count.withLock { $0 = 0 }
        for typed in ["s", "sw", "swi", "swift", "swift.org", "https://swift.org/documentation/", "swift docs"] {
            suggestions.update(typed)
            await suggestions.historyRead?.value
        }
        #expect(suggestions.rows.contains { $0.kind == .history })
        #expect(CountingProtocol.count.withLock { $0 } == 0)
        _ = try? await URLSession.shared.data(from: URL(string: "https://counter.invalid/")!)
        #expect(CountingProtocol.count.withLock { $0 } > 0)
    }
}
