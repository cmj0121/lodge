import Foundation
import Synchronization
import Testing

@testable import LodgeKit

@Suite struct HistoryRecorderTests {
    private let store: HistoryStore
    private let recorder: HistoryRecorder
    private let tab = UUID()
    private let other = UUID()

    init() throws {
        store = try HistoryStore.inMemory()
        // Each event is a minute later than the last, so the store never coalesces on its own.
        let ticks = Ticks()
        recorder = HistoryRecorder(store: store, clock: { ticks.next() })
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func visits() async throws -> [(String, String)] {
        await recorder.drain()
        return try await store.page(before: nil, limit: 100).map { ($0.url.absoluteString, $0.title) }.reversed()
    }

    @Test func eventsAreAppliedInOrder() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: ""))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.committed(tab: tab, url: url("https://b.example/"), title: "B"))
        recorder.send(.title(tab: tab, url: url("https://b.example/"), title: "B2"))
        #expect(try await visits().elementsEqual([("https://a.example/", "A"), ("https://b.example/", "B2")], by: ==))
    }

    @Test func urlChangedToTheSameURLIsIgnored() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/#part"), title: "A"))
        #expect(try await visits().map(\.0) == ["https://a.example/", "https://a.example/#part"])
    }

    @Test func seenRecordsNothingButSetsTheLastURL() async throws {
        recorder.send(.seen(tab: tab, url: url("https://a.example/")))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: "A"))
        #expect(try await visits().isEmpty)
    }

    @Test func aBlankTitleKeepsTheVisitsTitle() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: ""))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: "  "))
        #expect(try await visits().elementsEqual([("https://a.example/", "A")], by: ==))
    }

    @Test func aFinishedLoadOnTheCommittedURLAddsNoVisit() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/"), title: "A"))
        #expect(try await visits().map(\.0) == ["https://a.example/"])
    }

    @Test func aFinishedLoadOnARoutedURLAddsAVisit() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/app/home"), title: "A"))
        #expect(try await visits().map(\.0) == ["https://a.example/", "https://a.example/app/home"])
    }

    @Test func aURLChangeToTheSeenURLAddsNoVisit() async throws {
        recorder.send(.seen(tab: tab, url: url("https://r.example/")))
        recorder.send(.urlChanged(tab: tab, url: url("https://r.example/"), title: "R"))
        #expect(try await visits().isEmpty)
    }

    @Test func aCommitAfterSeenIsRecorded() async throws {
        recorder.send(.seen(tab: tab, url: url("https://a.example/")))
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/#part"), title: "A"))
        #expect(try await visits().map(\.0) == ["https://a.example/", "https://a.example/#part"])
    }

    @Test func titleAppliesOnlyWhileTheVisitIsStillShown() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: ""))
        recorder.send(.committed(tab: other, url: url("https://b.example/"), title: ""))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: "A"))
        recorder.send(.seen(tab: tab, url: url("https://c.example/")))
        recorder.send(.title(tab: tab, url: url("https://c.example/"), title: "C"))
        #expect(try await visits().elementsEqual([("https://a.example/", "A"), ("https://b.example/", "")], by: ==))
    }

    @Test func aTitleLandsOnlyOnItsOwnPagesVisit() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: "A"))
        // The commit of B was dropped (or never sent), so the tab's state still points at A's visit.
        recorder.send(.title(tab: tab, url: url("https://b.example/"), title: "B"))
        #expect(try await visits().elementsEqual([("https://a.example/", "A")], by: ==))
    }

    @Test func closedForgetsTheTab() async throws {
        recorder.send(.committed(tab: tab, url: url("https://a.example/"), title: ""))
        recorder.send(.closed(tab: tab))
        recorder.send(.title(tab: tab, url: url("https://a.example/"), title: "Late"))
        recorder.send(.urlChanged(tab: tab, url: url("https://a.example/"), title: "Again"))
        #expect(try await visits().elementsEqual([("https://a.example/", ""), ("https://a.example/", "Again")], by: ==))
    }

    @Test func onlyWebPagesAreRecorded() async throws {
        recorder.send(.committed(tab: tab, url: url("about:blank"), title: ""))
        recorder.send(.title(tab: tab, url: url("about:blank"), title: "Blank"))
        recorder.send(.committed(tab: tab, url: url("file:///tmp/x.html"), title: "File"))
        recorder.send(.committed(tab: tab, url: url("HTTPS://a.example/"), title: "A"))
        #expect(try await visits().map(\.1) == ["A"])
    }

    @Test func overlongURLsAreRefusedNotCut() async throws {
        let long = url("https://a.example/" + String(repeating: "x", count: HistoryRecorder.urlLimit))
        recorder.send(.committed(tab: tab, url: long, title: "Long"))
        recorder.send(.title(tab: tab, url: long, title: "Long again"))
        let fits = "https://b.example/" + String(repeating: "x", count: HistoryRecorder.urlLimit - 18)
        recorder.send(.committed(tab: tab, url: url(fits), title: "Fits"))
        #expect(try await visits().elementsEqual([(fits, "Fits")], by: ==))
    }

    @Test func credentialsAreStrippedBeforeRecording() async throws {
        recorder.send(.committed(tab: tab, url: url("https://bob:secret@a.example/x?q=1"), title: ""))
        recorder.send(.title(tab: tab, url: url("https://bob:secret@a.example/x?q=1"), title: "A"))
        recorder.send(.committed(tab: tab, url: url("https://alice@b.example/"), title: "B"))
        #expect(try await visits().elementsEqual([("https://a.example/x?q=1", "A"), ("https://b.example/", "B")], by: ==))
    }
}

@Suite struct HistoryRecorderRateTests {
    private let store: HistoryStore
    private let recorder: HistoryRecorder
    private let clock = ManualClock()
    private let tab = UUID()

    init() throws {
        store = try HistoryStore.inMemory()
        recorder = HistoryRecorder(store: store, clock: { [clock] in clock.now() })
    }

    private func visits() async throws -> [HistoryVisit] {
        await recorder.drain()
        return try await store.page(before: nil, limit: 1000).reversed()
    }

    @Test func pastTheRateLimitNewRowsAreDroppedButRevisitsStillRefresh() async throws {
        for i in 0..<HistoryRecorder.rateLimit {
            recorder.send(.committed(tab: tab, url: URL(string: "https://a.example/\(i)")!, title: "P\(i)"))
        }
        let newest = URL(string: "https://a.example/\(HistoryRecorder.rateLimit - 1)")!
        recorder.send(.committed(tab: tab, url: URL(string: "https://a.example/over")!, title: "Over"))
        recorder.send(.title(tab: tab, url: URL(string: "https://a.example/over")!, title: "Over again"))
        var rows = try await visits()
        #expect(rows.count == HistoryRecorder.rateLimit)
        #expect(rows.last?.url == newest)
        clock.advance(10)
        recorder.send(.committed(tab: tab, url: newest, title: "Refreshed"))
        recorder.send(.committed(tab: UUID(), url: URL(string: "https://other.example/")!, title: "O"))
        rows = try await visits()
        #expect(rows.count == HistoryRecorder.rateLimit + 1)
        #expect(rows.suffix(2).map(\.title) == ["Refreshed", "O"])
        clock.advance(HistoryRecorder.rateWindow)
        recorder.send(.committed(tab: tab, url: URL(string: "https://a.example/later")!, title: "L"))
        rows = try await visits()
        #expect(rows.last?.title == "L")
        #expect(rows.count == HistoryRecorder.rateLimit + 2)
    }
}

@Suite struct HistoryRecorderQueueTests {
    @Test func aFloodKeepsTheNewestEvents() async throws {
        let store = BlockingStore()
        let ticks = Ticks()
        let recorder = HistoryRecorder(writing: store, clock: { ticks.next() })
        let tab = UUID()
        recorder.send(.committed(tab: tab, url: URL(string: "https://first.example/")!, title: ""))
        await store.firstRecordStarted()
        let flood = HistoryRecorder.queueLimit * 3
        for i in 0..<flood {
            recorder.send(.committed(tab: tab, url: URL(string: "https://a.example/\(i)")!, title: ""))
        }
        // The drain waits outside the full queue, so the flood cannot drop it, and it returns only once the
        // newest event is applied.
        let drained = Task { await recorder.drain() }
        store.release()
        await drained.value
        let calls = store.calls()
        #expect(calls.count <= HistoryRecorder.queueLimit + 1)
        #expect(calls.last == "https://a.example/\(flood - 1)")
    }

    @Test func aDrainWithNothingQueuedReturnsAtOnce() async {
        let recorder = HistoryRecorder(writing: BlockingStore(), clock: Date.init)
        await recorder.drain()
        await recorder.drain()
    }
}

@Suite struct HistoryRecorderFailureTests {
    @Test func aFailedRecordLeavesNoVisitForALaterTitle() async throws {
        let store = FailingStore(failing: [URL(string: "https://b.example/")!, URL(string: "https://c.example/")!])
        let ticks = Ticks()
        let recorder = HistoryRecorder(writing: store, clock: { ticks.next() })
        let tab = UUID()
        recorder.send(.committed(tab: tab, url: URL(string: "https://a.example/")!, title: ""))
        recorder.send(.committed(tab: tab, url: URL(string: "https://b.example/")!, title: ""))
        recorder.send(.title(tab: tab, url: URL(string: "https://b.example/")!, title: "B"))
        recorder.send(.urlChanged(tab: tab, url: URL(string: "https://b.example/")!, title: "B"))
        recorder.send(.urlChanged(tab: tab, url: URL(string: "https://c.example/")!, title: ""))
        recorder.send(.title(tab: tab, url: URL(string: "https://c.example/")!, title: "C"))
        await recorder.drain()
        #expect(store.calls() == ["record https://a.example/", "record https://b.example/", "record https://c.example/"])
    }
}

/// Fails to record the given URLs and logs every write it is asked for.
private final class FailingStore: HistoryWriting {
    private struct WriteFailed: Error {}

    private let failing: Set<URL>
    private let log = Mutex<[String]>([])

    init(failing: Set<URL>) {
        self.failing = failing
    }

    func calls() -> [String] { log.withLock { $0 } }

    func record(_ url: URL, title: String, at date: Date) async throws -> Int64 {
        let count = log.withLock { log in
            log.append("record \(url.absoluteString)")
            return log.count
        }
        if failing.contains(url) { throw WriteFailed() }
        return Int64(count)
    }

    func refresh(_ url: URL, title: String, at date: Date) async throws -> Int64? {
        log.withLock { $0.append("refresh \(url.absoluteString)") }
        return nil
    }

    func updateTitle(of id: Int64, to title: String) async throws {
        log.withLock { $0.append("title \(id) \(title)") }
    }
}

/// Holds its first record until `release`, so events pile up in the recorder's queue; logs every recorded URL.
private final class BlockingStore: HistoryWriting {
    private let log = Mutex<[String]>([])
    private let started = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func calls() -> [String] { log.withLock { $0 } }

    func firstRecordStarted() async {
        for await _ in started.stream { return }
    }

    func release() { released.continuation.finish() }

    func record(_ url: URL, title: String, at date: Date) async throws -> Int64 {
        let count = log.withLock { log in
            log.append(url.absoluteString)
            return log.count
        }
        if count == 1 {
            started.continuation.yield()
            for await _ in released.stream {}
        }
        return Int64(count)
    }

    func refresh(_ url: URL, title: String, at date: Date) async throws -> Int64? { nil }

    func updateTitle(of id: Int64, to title: String) async throws {}
}

/// A clock that stays put until `advance`.
private final class ManualClock: Sendable {
    private let date = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))

    func now() -> Date { date.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// A clock that moves a minute forward on every reading.
private final class Ticks: Sendable {
    private let count = Mutex(0)

    func next() -> Date {
        count.withLock { count in
            count += 1
            return Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(count) * 60)
        }
    }
}
