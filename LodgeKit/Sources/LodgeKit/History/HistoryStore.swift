import Foundation
import GRDB
import os

/// One row of browsing history.
public struct HistoryVisit: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let url: URL
    public let title: String
    public let visitedAt: Date

    public init(id: Int64, url: URL, title: String, visitedAt: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }

    fileprivate init(row: Row) {
        self.init(id: row["id"], url: row["url"], title: row["title"], visitedAt: row["visitedAt"])
    }
}

/// Browsing history in SQLite: `history.sqlite` in a folder, or in memory for tests.
public final class HistoryStore: Sendable {
    /// A revisit of the newest row's URL within this many seconds updates that row instead of adding one.
    static let coalesceInterval: TimeInterval = 30

    static let fileName = "history.sqlite"

    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    /// Why an existing file cannot be used and is set aside, as opposed to a failure that leaves it in place.
    private enum Unusable: Error {
        case corrupt(any Error)
        case failedCheck(String?)
        case failedMigration(any Error)
    }

    /// Result codes that say the file itself is bad; any other open failure (busy, full, I/O…) leaves it alone.
    private static let corruptionCodes: [ResultCode] = [.SQLITE_NOTADB, .SQLITE_CORRUPT]

    /// Result codes of a migration that failed for reasons outside the file, so it is not set aside.
    private static let environmentCodes: [ResultCode] = [
        .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN, .SQLITE_READONLY,
        .SQLITE_PERM, .SQLITE_NOMEM, .SQLITE_INTERRUPT,
    ]

    private let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Opens `history.sqlite` in `directory`, creating both when missing. A file that is not a database, fails
    /// `PRAGMA quick_check`, or whose migration fails, is moved aside to `history.sqlite.bad` (with its `-wal`
    /// and `-shm`, replacing older ones) and a fresh one is created. Other failures are thrown and leave the
    /// file in place. It runs a full `PRAGMA quick_check`, which reads the whole file, so never call it on the
    /// main actor.
    public static func open(directory: URL) throws -> HistoryStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName)
        do {
            return try openPool(at: url)
        } catch let error as Unusable {
            logger.error("History file is unusable, setting it aside: \(String(describing: error), privacy: .public)")
            try setAside(url)
            return try openPool(at: url)
        }
    }

    /// A store that lives only as long as the returned object.
    public static func inMemory() throws -> HistoryStore {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return HistoryStore(writer: queue)
    }

    private static func isCorruption(_ error: any Error) -> Bool {
        (error as? DatabaseError).map { corruptionCodes.contains($0.resultCode.primaryResultCode) } ?? false
    }

    /// Opens and migrates the file, throwing `Unusable` only when the file itself is at fault.
    private static func openPool(at url: URL) throws -> HistoryStore {
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path(percentEncoded: false))
        } catch where isCorruption(error) {
            throw Unusable.corrupt(error)
        }
        do {
            let check = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA quick_check") }
            guard check == "ok" else { throw Unusable.failedCheck(check) }
            do {
                try migrator.migrate(pool)
            } catch let error as DatabaseError where !environmentCodes.contains(error.resultCode.primaryResultCode) {
                throw Unusable.failedMigration(error)
            }
            return HistoryStore(writer: pool)
        } catch {
            try? pool.close()
            throw isCorruption(error) ? Unusable.corrupt(error) : error
        }
    }

    private static func setAside(_ url: URL) throws {
        let files = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: url.path(percentEncoded: false) + suffix)
            let target = URL(filePath: url.path(percentEncoded: false) + ".bad" + suffix)
            if files.fileExists(atPath: target.path(percentEncoded: false)) { try files.removeItem(at: target) }
            if files.fileExists(atPath: source.path(percentEncoded: false)) { try files.moveItem(at: source, to: target) }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "visit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("visitedAt", .datetime).notNull()
            }
            try db.create(index: "visit_on_visitedAt", on: "visit", columns: ["visitedAt", "id"])
            try db.create(virtualTable: "visit_ft", using: FTS5()) { t in
                t.synchronize(withTable: "visit")
                // GRDB has no descriptor for SQLite's trigram tokenizer (case-insensitive by default).
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("title")
                t.column("url")
            }
        }
        return migrator
    }

    /// Adds a visit and returns its id, or refreshes the newest row when it is the same URL less than
    /// `coalesceInterval` older than `date` (taking `title` when it is not empty) and returns that row's id.
    @discardableResult
    public func record(_ url: URL, title: String, at date: Date) async throws -> Int64 {
        try await writer.write { db in
            if let newest = try Row.fetchOne(
                db, sql: "SELECT id, url, visitedAt FROM visit ORDER BY visitedAt DESC, id DESC LIMIT 1"),
                newest["url"] as URL == url,
                date.timeIntervalSince(newest["visitedAt"] as Date) < Self.coalesceInterval
            {
                let id: Int64 = newest["id"]
                if title.isEmpty {
                    try db.execute(sql: "UPDATE visit SET visitedAt = ? WHERE id = ?", arguments: [date, id])
                } else {
                    try db.execute(
                        sql: "UPDATE visit SET visitedAt = ?, title = ? WHERE id = ?", arguments: [date, title, id])
                }
                return id
            }
            try db.execute(
                sql: "INSERT INTO visit (url, title, visitedAt) VALUES (?, ?, ?)", arguments: [url, title, date])
            return db.lastInsertedRowID
        }
    }

    /// Sets the title of visit `id`; does nothing when that row is gone.
    public func updateTitle(of id: Int64, to title: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE visit SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    /// Newest first; `before` nil = from now. Uses the visitedAt index. Visits at exactly `before` are left
    /// out, which is why callers outside LodgeKit page with `page(after:limit:)`.
    func page(before: Date?, limit: Int) async throws -> [HistoryVisit] {
        try await writer.read { db in
            if let before {
                try Row.fetchAll(
                    db, sql: "SELECT * FROM visit WHERE visitedAt < ? ORDER BY visitedAt DESC, id DESC LIMIT ?",
                    arguments: [before, limit]
                ).map(HistoryVisit.init(row:))
            } else {
                try Row.fetchAll(db, sql: "SELECT * FROM visit ORDER BY visitedAt DESC, id DESC LIMIT ?", arguments: [limit])
                    .map(HistoryVisit.init(row:))
            }
        }
    }

    /// Newest first, starting after `cursor` (nil = from the newest), so visits sharing a `visitedAt` are never
    /// skipped or repeated across pages.
    public func page(after cursor: HistoryVisit?, limit: Int) async throws -> [HistoryVisit] {
        guard let cursor else { return try await page(before: nil, limit: limit) }
        return try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM visit WHERE (visitedAt, id) < (?, ?) ORDER BY visitedAt DESC, id DESC LIMIT ?",
                arguments: [cursor.visitedAt, cursor.id, limit]
            ).map(HistoryVisit.init(row:))
        }
    }

    /// Trimmed query; empty → []. ≥ 3 characters: FTS5 (trigram tokenizer, case-insensitive) phrase MATCH over
    /// title + url; 1–2 characters (e.g. two CJK chars): LIKE with %/_ escaped. Newest first, `limit` rows.
    public func search(_ query: String, limit: Int) async throws -> [HistoryVisit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        // Trigrams are counted in Unicode scalars, so this also catches short queries of combined scalars.
        if query.unicodeScalars.count >= 3 {
            let phrase = "\"" + query.replacing("\"", with: "\"\"") + "\""
            return try await writer.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT visit.* FROM visit JOIN visit_ft ON visit_ft.rowid = visit.id
                        WHERE visit_ft MATCH ? ORDER BY visit.visitedAt DESC, visit.id DESC LIMIT ?
                        """,
                    arguments: [phrase, limit]
                ).map(HistoryVisit.init(row:))
            }
        }
        let escaped = query.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM visit WHERE title LIKE ?1 ESCAPE '\\' OR url LIKE ?1 ESCAPE '\\'
                    ORDER BY visitedAt DESC, id DESC LIMIT ?2
                    """,
                arguments: [pattern, limit]
            ).map(HistoryVisit.init(row:))
        }
    }

    /// Deletes every visit, then compacts the file.
    public func clearAll() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM visit")
        }
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    /// Yields once as soon as the observation is live, then after each committed change to the visits (changes
    /// close together may yield once). Starting it never blocks the caller.
    public func changes() -> AsyncStream<Void> {
        let values = ValueObservation.tracking(regions: [Table("visit")], fetch: { _ in })
            .values(in: writer, bufferingPolicy: .bufferingNewest(1))
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            do {
                for try await _ in values { continuation.yield() }
            } catch {
                Self.logger.error("History observation failed: \(error, privacy: .public)")
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
