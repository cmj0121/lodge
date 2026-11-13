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

    /// Nil for a row whose url or date does not decode, such as one written by something other than this store,
    /// where GRDB's typed subscripts would trap.
    fileprivate init?(row: Row) {
        guard let text = String.fromDatabaseValue(row["url"]), let url = URL(string: text),
            let visitedAt = Date.fromDatabaseValue(row["visitedAt"])
        else { return nil }
        self.init(id: row["id"], url: url, title: String.fromDatabaseValue(row["title"]) ?? "", visitedAt: visitedAt)
    }
}

/// Browsing history in SQLite: `history.sqlite` in a folder, or in memory for tests.
public final class HistoryStore: Sendable {
    /// A revisit of the newest row's URL within this many seconds updates that row instead of adding one.
    static let coalesceInterval: TimeInterval = 30

    static let fileName = "history.sqlite"

    /// Titles are cut to this many Unicode scalars before they are stored.
    static let titleLimit = 512

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

    /// What `clearAll` throws when the visits are gone but some of the old data is still on disk.
    public enum ClearError: Error {
        /// A reader kept `history.sqlite-wal` from being emptied; it is emptied when the last connection closes.
        case checkpointBusy
    }

    /// `clearAll` tries the checkpoint this many times, `checkpointDelay` apart, while readers keep it busy.
    static let checkpointAttempts = 5
    static let checkpointDelay = Duration.milliseconds(50)

    private let writer: any DatabaseWriter
    /// `history.sqlite`, nil in memory.
    private let file: URL?

    private init(writer: any DatabaseWriter, file: URL? = nil) {
        self.writer = writer
        self.file = file
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
            // A WAL left by a run that never closed the store (a forced quit, a crash) may still hold cleared
            // visits; empty it now, and have every later checkpoint shrink it back to nothing.
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_size_limit = 0")
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return HistoryStore(writer: pool, file: url)
        } catch {
            try? pool.close()
            throw isCorruption(error) ? Unusable.corrupt(error) : error
        }
    }

    private static let fileSuffixes = ["", "-wal", "-shm"]

    private static func setAside(_ url: URL) throws {
        let files = FileManager.default
        for suffix in fileSuffixes {
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

    private static func clipped(_ title: String) -> String {
        title.unicodeScalars.count > titleLimit
            ? String(String.UnicodeScalarView(title.unicodeScalars.prefix(titleLimit))) : title
    }

    /// Adds a visit and returns its id, or refreshes the newest row when it is the same URL less than
    /// `coalesceInterval` older than `date` (taking `title` when it is not empty) and returns that row's id.
    /// `title` is cut to `titleLimit` scalars.
    @discardableResult
    public func record(_ url: URL, title: String, at date: Date) async throws -> Int64 {
        let title = Self.clipped(title)
        return try await writer.write { db in
            if let id = try Self.coalesce(url, title: title, at: date, in: db) { return id }
            try db.execute(
                sql: "INSERT INTO visit (url, title, visitedAt) VALUES (?, ?, ?)", arguments: [url, title, date])
            return db.lastInsertedRowID
        }
    }

    /// What `record` does when it would refresh the newest row; nil, writing nothing, when it would add one.
    func refresh(_ url: URL, title: String, at date: Date) async throws -> Int64? {
        let title = Self.clipped(title)
        return try await writer.write { db in try Self.coalesce(url, title: title, at: date, in: db) }
    }

    private static func coalesce(_ url: URL, title: String, at date: Date, in db: Database) throws -> Int64? {
        guard
            let newest = try Row.fetchOne(
                db, sql: "SELECT id, url, visitedAt FROM visit ORDER BY visitedAt DESC, id DESC LIMIT 1"),
            String.fromDatabaseValue(newest["url"]) == url.absoluteString,
            let newestAt = Date.fromDatabaseValue(newest["visitedAt"]),
            date.timeIntervalSince(newestAt) < coalesceInterval
        else { return nil }
        let id: Int64 = newest["id"]
        if title.isEmpty {
            try db.execute(sql: "UPDATE visit SET visitedAt = ? WHERE id = ?", arguments: [date, id])
        } else {
            try db.execute(sql: "UPDATE visit SET visitedAt = ?, title = ? WHERE id = ?", arguments: [date, title, id])
        }
        return id
    }

    /// Sets the title of visit `id`, cut to `titleLimit` scalars; does nothing when that row is gone.
    public func updateTitle(of id: Int64, to title: String) async throws {
        let title = Self.clipped(title)
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
                ).compactMap(HistoryVisit.init(row:))
            } else {
                try Row.fetchAll(db, sql: "SELECT * FROM visit ORDER BY visitedAt DESC, id DESC LIMIT ?", arguments: [limit])
                    .compactMap(HistoryVisit.init(row:))
            }
        }
    }

    /// Newest first, starting after `cursor` (nil = from the newest), so visits sharing a `visitedAt` are never
    /// skipped or repeated across pages. Rows that do not decode are skipped and the page is filled from the rows
    /// after them, so a short page still means the end.
    public func page(after cursor: HistoryVisit?, limit: Int) async throws -> [HistoryVisit] {
        try await writer.read { db in
            var visits: [HistoryVisit] = []
            var after: [DatabaseValue]? = cursor.map { [$0.visitedAt.databaseValue, $0.id.databaseValue] }
            while visits.count < limit {
                let wanted = limit - visits.count
                let rows =
                    if let after {
                        try Row.fetchAll(
                            db,
                            sql: """
                                SELECT * FROM visit WHERE (visitedAt, id) < (?, ?) ORDER BY visitedAt DESC, id DESC
                                LIMIT ?
                                """,
                            arguments: [after[0], after[1], wanted])
                    } else {
                        try Row.fetchAll(
                            db, sql: "SELECT * FROM visit ORDER BY visitedAt DESC, id DESC LIMIT ?", arguments: [wanted])
                    }
                visits += rows.compactMap(HistoryVisit.init(row:))
                guard rows.count == wanted, let last = rows.last else { break }
                after = [last["visitedAt"], last["id"]]
            }
            return visits
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
                ).compactMap(HistoryVisit.init(row:))
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
            ).compactMap(HistoryVisit.init(row:))
        }
    }

    /// Deletes every visit and the search index's copy of them, compacts the file and empties the `-wal`, so no
    /// deleted title or URL is left in the files' free pages. Also removes the files `open` set aside. Throws
    /// `ClearError.checkpointBusy`, with the visits already deleted, when readers keep the `-wal` from emptying.
    public func clearAll() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM visit")
            // DELETE leaves the old trigram segments in `visit_ft_data` until FTS5 merges them.
            try db.execute(sql: "INSERT INTO visit_ft(visit_ft) VALUES('delete-all')")
        }
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        if let file {
            let files = FileManager.default
            for suffix in Self.fileSuffixes {
                let bad = URL(filePath: file.path(percentEncoded: false) + ".bad" + suffix)
                if files.fileExists(atPath: bad.path(percentEncoded: false)) { try files.removeItem(at: bad) }
            }
        }
        for attempt in 1...Self.checkpointAttempts {
            // The first column is 1 when a reader kept the checkpoint from finishing.
            let busy = try await writer.writeWithoutTransaction { db in
                try Int.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") ?? 0
            }
            if busy == 0 { return }
            if attempt < Self.checkpointAttempts { try await Task.sleep(for: Self.checkpointDelay) }
        }
        throw ClearError.checkpointBusy
    }

    /// Empties the `-wal` as far as readers allow, then closes the file; later reads and writes throw. Call it as
    /// the app quits, so what a busy `clearAll` left in the `-wal` is gone before the next launch.
    public func close() throws {
        try writer.writeWithoutTransaction { db in
            // Busy only means a reader is still open; closing the last connection checkpoints again.
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try writer.close()
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
