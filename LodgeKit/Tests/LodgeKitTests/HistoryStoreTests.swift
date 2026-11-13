import Foundation
import GRDB
import SQLite3
import Testing

@testable import LodgeKit

/// In-memory stores, or each test's own fresh temporary folder, never the app's real history.
@Suite struct HistoryStoreTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID())")
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func url(_ text: String) -> URL { URL(string: text)! }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func all(_ store: HistoryStore) async throws -> [HistoryVisit] {
        try await store.page(before: nil, limit: 1000)
    }

    @Test func recordInsertsAVisit() async throws {
        let store = try HistoryStore.inMemory()
        let id = try await store.record(url("https://a.example/"), title: "A", at: start)
        #expect(try await all(store) == [HistoryVisit(id: id, url: url("https://a.example/"), title: "A", visitedAt: start)])
    }

    @Test func sameURLWithin30SecondsUpdatesTheRow() async throws {
        let store = try HistoryStore.inMemory()
        let first = try await store.record(url("https://a.example/"), title: "", at: start)
        let second = try await store.record(url("https://a.example/"), title: "A", at: start + 10)
        let third = try await store.record(url("https://a.example/"), title: "", at: start + 20)
        #expect(first == second && second == third)
        #expect(try await all(store) == [HistoryVisit(id: first, url: url("https://a.example/"), title: "A", visitedAt: start + 20)])
    }

    @Test func sameURLAfter30SecondsOrAfterAnotherPageInserts() async throws {
        let store = try HistoryStore.inMemory()
        let a1 = try await store.record(url("https://a.example/"), title: "A", at: start)
        let a2 = try await store.record(url("https://a.example/"), title: "A", at: start + 30)
        let b = try await store.record(url("https://b.example/"), title: "B", at: start + 31)
        let a3 = try await store.record(url("https://a.example/"), title: "A", at: start + 32)
        #expect(Set([a1, a2, b, a3]).count == 4)
        #expect(try await all(store).map(\.id) == [a3, b, a2, a1])
    }

    @Test func updateTitleChangesTheRowAndIgnoresAMissingID() async throws {
        let store = try HistoryStore.inMemory()
        let id = try await store.record(url("https://a.example/"), title: "", at: start)
        try await store.updateTitle(of: id, to: "Later")
        try await store.updateTitle(of: id + 99, to: "Nobody")
        #expect(try await all(store).map(\.title) == ["Later"])
    }

    @Test func pageIsNewestFirstAndPagesWithBefore() async throws {
        let store = try HistoryStore.inMemory()
        for i in 0..<5 {
            try await store.record(url("https://p.example/\(i)"), title: "\(i)", at: start + Double(i) * 60)
        }
        let first = try await store.page(before: nil, limit: 2)
        #expect(first.map(\.title) == ["4", "3"])
        let second = try await store.page(before: first.last?.visitedAt, limit: 2)
        #expect(second.map(\.title) == ["2", "1"])
        let rest = try await store.page(before: second.last?.visitedAt, limit: 2)
        #expect(rest.map(\.title) == ["0"])
    }

    @Test func cursorPagingKeepsVisitsThatShareATime() async throws {
        let store = try HistoryStore.inMemory()
        let older = try await store.record(url("https://o.example/"), title: "O", at: start)
        var tied: [Int64] = []
        for i in 0..<3 {
            tied.append(try await store.record(url("https://t.example/\(i)"), title: "T\(i)", at: start + 60))
        }
        let first = try await store.page(after: nil, limit: 2)
        #expect(first.map(\.id) == [tied[2], tied[1]])
        let second = try await store.page(after: first.last, limit: 2)
        #expect(second.map(\.id) == [tied[0], older])
        #expect(try await store.page(after: second.last, limit: 2).isEmpty)
    }

    @Test func searchMatchesTitleOrURLCaseInsensitively() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(url("https://swift.org/docs"), title: "Documentation", at: start)
        try await store.record(url("https://example.com/"), title: "Learning SWIFT", at: start + 60)
        try await store.record(url("https://other.example/"), title: "Nothing here", at: start + 120)
        #expect(try await store.search("Swift", limit: 10).map(\.title) == ["Learning SWIFT", "Documentation"])
        #expect(try await store.search("  umenta ", limit: 10).map(\.title) == ["Documentation"])
        #expect(try await store.search("org/do", limit: 10).map(\.title) == ["Documentation"])
        #expect(try await store.search("\"quoted\" OR x", limit: 10).isEmpty)
        #expect(try await store.search("   ", limit: 10).isEmpty)
        #expect(try await store.search("swift", limit: 1).map(\.title) == ["Learning SWIFT"])
    }

    @Test func shortSearchUsesLikeWithLiteralWildcards() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(url("https://tw.example/"), title: "台灣新聞", at: start)
        try await store.record(url("https://pct.example/"), title: "100% sure", at: start + 60)
        try await store.record(url("https://under.example/a_b"), title: "Under", at: start + 120)
        try await store.record(url("https://plain.example/"), title: "Plain", at: start + 180)
        #expect(try await store.search("台灣", limit: 10).map(\.title) == ["台灣新聞"])
        #expect(try await store.search("%", limit: 10).map(\.title) == ["100% sure"])
        #expect(try await store.search("_", limit: 10).map(\.title) == ["Under"])
        #expect(try await store.search("UN", limit: 10).map(\.title) == ["Under"])
    }

    @Test func searchFollowsTitleUpdatesAndClearAll() async throws {
        let store = try HistoryStore.inMemory()
        let id = try await store.record(url("https://a.example/"), title: "Loading", at: start)
        try await store.updateTitle(of: id, to: "Kittens")
        #expect(try await store.search("Loading", limit: 10).isEmpty)
        #expect(try await store.search("kitten", limit: 10).map(\.id) == [id])
        try await store.clearAll()
        #expect(try await store.search("kitten", limit: 10).isEmpty)
        let again = try await store.record(url("https://b.example/"), title: "Kittens again", at: start + 60)
        #expect(try await store.search("kitten", limit: 10).map(\.id) == [again])
    }

    @Test func clearAllEmptiesTheStore() async throws {
        let store = try HistoryStore.inMemory()
        try await store.record(url("https://a.example/"), title: "A", at: start)
        try await store.record(url("https://b.example/"), title: "B", at: start + 60)
        try await store.clearAll()
        #expect(try await all(store).isEmpty)
    }

    @Test func historyPersistsAcrossReopen() async throws {
        defer { cleanUp() }
        let id = try await HistoryStore.open(directory: root).record(url("https://a.example/"), title: "A", at: start)
        let reopened = try HistoryStore.open(directory: root)
        #expect(try await all(reopened).map(\.id) == [id])
        #expect(try await reopened.search("a.example", limit: 10).map(\.id) == [id])
    }

    @Test func corruptFileIsSetAsideAndTheStoreOpensEmpty() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "history.sqlite")
        let garbage = Data(repeating: 0xA5, count: 8192)
        try garbage.write(to: file)
        try Data("stale".utf8).write(to: root.appending(path: "history.sqlite.bad"))
        let store = try HistoryStore.open(directory: root)
        #expect(try await all(store).isEmpty)
        #expect(try Data(contentsOf: root.appending(path: "history.sqlite.bad")) == garbage)
        try await store.record(url("https://a.example/"), title: "A", at: start)
        #expect(try await all(store).count == 1)
    }

    @Test func corruptPagesAreSetAside() async throws {
        defer { cleanUp() }
        do {
            let store = try HistoryStore.open(directory: root)
            for i in 0..<2000 {
                try await store.record(url("https://c.example/\(i)"), title: "Page \(i)", at: start + Double(i) * 60)
            }
        }
        let file = root.appending(path: "history.sqlite")
        let wal = try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false) + "-wal")
        #expect((wal?[.size] as? Int ?? 0) == 0, "every page is back in the main file")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 4096 * 3)
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096 * 4))
        try handle.close()
        let store = try HistoryStore.open(directory: root)
        #expect(try await all(store).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "history.sqlite.bad").path(percentEncoded: false)))
    }

    @Test func aBusyFileIsLeftInPlace() async throws {
        defer { cleanUp() }
        let file = root.appending(path: "history.sqlite")
        try await HistoryStore.open(directory: root).record(url("https://a.example/"), title: "A", at: start)
        let before = try Data(contentsOf: file)
        // Another process holding the file locked, which SQLite on macOS reports as busy.
        let lock = try FileHandle(forUpdating: file)
        defer { try? lock.close() }
        #expect(flock(lock.fileDescriptor, LOCK_EX) == 0)
        let error = #expect(throws: (any Error).self) { try HistoryStore.open(directory: root) }
        #expect(String(describing: error).contains("SQLite error 5"), "SQLITE_BUSY")
        #expect(try Data(contentsOf: file) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "history.sqlite.bad").path(percentEncoded: false)))
    }

    @Test func changesYieldsAfterAWrite() async throws {
        let store = try HistoryStore.inMemory()
        var changes = store.changes().makeAsyncIterator()
        #expect(await changes.next() != nil)
        try await store.record(url("https://a.example/"), title: "A", at: start)
        #expect(await changes.next() != nil)
        try await store.clearAll()
        #expect(await changes.next() != nil)
    }

    @Test func tenThousandRowsPageAndSearchQuickly() async throws {
        let store = try HistoryStore.inMemory()
        for i in 0..<10_000 {
            try await store.record(url("https://site\(i % 100).example/page/\(i)"), title: "Page \(i)", at: start + Double(i))
        }
        let clock = ContinuousClock()
        let began = clock.now
        #expect(try await store.page(before: nil, limit: 200).count == 200)
        #expect(try await store.page(before: start + 5000, limit: 200).first?.title == "Page 4999")
        #expect(try await store.search("site42.ex", limit: 200).count == 100)
        #expect(try await store.search("ge 9", limit: 200).count == 200)
        #expect(clock.now - began < .seconds(2))
    }

    @Test func clearAllLeavesNoTraceInTheFiles() async throws {
        defer { cleanUp() }
        let marker = "zqxmarker\(UUID().uuidString.prefix(8))"
        let store = try HistoryStore.open(directory: root)
        for i in 0..<200 {
            try await store.record(
                url("https://\(marker).example/\(i)"), title: "Title \(marker) \(i)", at: start + Double(i) * 60)
        }
        try await store.clearAll()
        for suffix in ["", "-wal", "-shm"] {
            let path = root.appending(path: "history.sqlite").path(percentEncoded: false) + suffix
            guard let bytes = FileManager.default.contents(atPath: path) else { continue }
            #expect(bytes.range(of: Data(marker.utf8)) == nil, "history.sqlite\(suffix)")
            // The trigram index stores three-scalar pieces, so look for one that only the marker has.
            #expect(bytes.range(of: Data(marker.prefix(3).utf8)) == nil, "history.sqlite\(suffix) trigram")
        }
        #expect(try await all(store).isEmpty)
    }

    @Test func clearAllRemovesSetAsideFiles() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 8192).write(to: root.appending(path: "history.sqlite"))
        let store = try HistoryStore.open(directory: root)
        for suffix in ["-wal", "-shm"] {
            try Data("old".utf8).write(to: root.appending(path: "history.sqlite.bad\(suffix)"))
        }
        try await store.clearAll()
        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(path: "history.sqlite.bad\(suffix)").path(percentEncoded: false)))
        }
    }

    @Test func titlesAreCutTo512Scalars() async throws {
        let store = try HistoryStore.inMemory()
        let long = String(repeating: "é", count: 2000)
        let id = try await store.record(url("https://a.example/"), title: long, at: start)
        #expect(try await all(store).map(\.title.unicodeScalars.count) == [HistoryStore.titleLimit])
        try await store.updateTitle(of: id, to: String(repeating: "x", count: 600))
        #expect(try await all(store).map(\.title) == [String(repeating: "x", count: HistoryStore.titleLimit)])
        #expect(try await store.refresh(url("https://a.example/"), title: long, at: start + 10) == id)
        #expect(try await all(store).map(\.title.unicodeScalars.count) == [HistoryStore.titleLimit])
    }

    @Test func refreshOnlyCoalescesAndNeverAddsARow() async throws {
        let store = try HistoryStore.inMemory()
        let id = try await store.record(url("https://a.example/"), title: "A", at: start)
        #expect(try await store.refresh(url("https://a.example/"), title: "", at: start + 10) == id)
        #expect(try await store.refresh(url("https://b.example/"), title: "B", at: start + 20) == nil)
        #expect(try await store.refresh(url("https://a.example/"), title: "A", at: start + 60) == nil)
        #expect(try await all(store) == [HistoryVisit(id: id, url: url("https://a.example/"), title: "A", visitedAt: start + 10)])
    }

    private func fileSize(_ name: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: root.appending(path: name).path(percentEncoded: false)))?[
            .size] as? Int
    }

    /// Whether any file in the store's folder holds `text`.
    private func filesContain(_ text: String) throws -> Bool {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { file in
            try Data(contentsOf: file).range(of: Data(text.utf8)) != nil
        }
    }

    /// An open read transaction on another connection holds the WAL snapshot, so the TRUNCATE checkpoint stays
    /// busy until it ends; closing the store afterwards empties the WAL. GRDB traps on a transaction left open
    /// past an access, so the reader is plain SQLite.
    @Test func aReaderKeepsClearAllFromEmptyingTheWALUntilClose() async throws {
        defer { cleanUp() }
        let marker = "zqxmarker\(UUID().uuidString.prefix(8))"
        let store = try HistoryStore.open(directory: root)
        for i in 0..<50 {
            try await store.record(url("https://\(marker).example/\(i)"), title: "\(marker) \(i)", at: start + Double(i) * 60)
        }
        var reader: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "history.sqlite").path(percentEncoded: false), &reader) == SQLITE_OK)
        #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM visit;", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: HistoryStore.ClearError.checkpointBusy) { try await store.clearAll() }
        #expect(try await all(store).isEmpty)
        #expect(try filesContain(marker), "the busy checkpoint left the old pages in the WAL")
        #expect(sqlite3_exec(reader, "COMMIT", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(reader) == SQLITE_OK)
        try store.close()
        let reopened = try HistoryStore.open(directory: root)
        #expect((fileSize("history.sqlite-wal") ?? 0) == 0)
        #expect(try !filesContain(marker))
        #expect(try !filesContain(String(marker.prefix(3))))
        #expect(try await all(reopened).isEmpty)
    }

    @Test func openEmptiesAWALLeftByAStoreThatNeverClosed() async throws {
        defer { cleanUp() }
        let left = try HistoryStore.open(directory: root)
        for i in 0..<20 {
            try await left.record(url("https://w.example/\(i)"), title: "W \(i)", at: start + Double(i) * 60)
        }
        #expect((fileSize("history.sqlite-wal") ?? 0) > 0)
        try withExtendedLifetime(left) {
            _ = try HistoryStore.open(directory: root)
            #expect((fileSize("history.sqlite-wal") ?? 0) == 0)
        }
    }

    @Test func closeEndsTheStore() async throws {
        defer { cleanUp() }
        let store = try HistoryStore.open(directory: root)
        try await store.record(url("https://a.example/"), title: "A", at: start)
        try store.close()
        #expect((fileSize("history.sqlite-wal") ?? 0) == 0)
        await #expect(throws: (any Error).self) { try await store.record(url("https://b.example/"), title: "B", at: start + 60) }
        #expect(try await all(HistoryStore.open(directory: root)).map(\.title) == ["A"])
    }

    @Test func rowsThatDoNotDecodeAreSkipped() async throws {
        defer { cleanUp() }
        let good = try await HistoryStore.open(directory: root).record(url("https://a.example/"), title: "A", at: start)
        // Rows written by something other than the store: an empty URL, bytes that are not text, and a bad date.
        let queue = try DatabaseQueue(path: root.appending(path: "history.sqlite").path(percentEncoded: false))
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO visit (url, title, visitedAt) VALUES ('', 'Empty sniff', '2099-01-01 00:00:00')")
            try db.execute(sql: "INSERT INTO visit (url, title, visitedAt) VALUES (X'FF', 'Blob sniff', '2099-01-02 00:00:00')")
            try db.execute(sql: "INSERT INTO visit (url, title, visitedAt) VALUES ('https://d.example/', 'Date sniff', 'soon')")
        }
        try queue.close()
        let store = try HistoryStore.open(directory: root)
        #expect(try await store.page(after: nil, limit: 1).map(\.id) == [good])
        #expect(try await store.page(after: nil, limit: 10).map(\.id) == [good])
        #expect(try await all(store).map(\.id) == [good])
        #expect(try await store.search("sniff", limit: 10).isEmpty)
        #expect(try await store.search("sn", limit: 10).isEmpty)
        try await store.record(url("https://b.example/"), title: "B", at: start + 60)
        #expect(try await all(store).count == 2)
    }
}
