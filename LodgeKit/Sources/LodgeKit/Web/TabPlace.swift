import Foundation

/// Where a resting tab was, as kept on disk (D5): its address, title and main-frame scroll position, and WebKit's
/// `interactionState` (back and forward history, scroll) only for a tab whose view never sent a form. That state holds
/// every sent form body in plain text, passwords included, and going Back onto a restored POST sends it again, so a
/// tab that sent a form, in its page or a frame, keeps the record alone.
public struct TabPlace: Equatable, Sendable {
    public var url: URL
    public var title: String
    /// The main frame's `scrollY` as the page last reported it; nil when it never did.
    public var scrollY: Double?
    /// WebKit's `interactionState`; nil for a record.
    public private(set) var state: Data?

    /// The hybrid rule: `state` is kept only when the view never sent a form (`sentForm` false).
    public init(url: URL, title: String, scrollY: Double?, state: Data?, sentForm: Bool) {
        self.url = url
        self.title = title
        self.scrollY = scrollY.flatMap(Self.validScroll)
        self.state = sentForm ? nil : state
    }

    /// Only the address, title and scroll position: WebKit's state is left out.
    public var isRecord: Bool { state == nil }

    /// How a tab wakes from its place.
    public enum Wake: Equatable, Sendable {
        /// Put back WebKit's state: the page, its history and scroll.
        case state(Data)
        /// Load the address, then scroll the main frame to `scrollY` when there is one (best effort).
        case load(URL, scrollY: Double?)
    }

    /// How a tab now on `url` wakes from this place; nil when the place is for another address (the tab moved on after
    /// it was written), so the tab just loads its address.
    public func wake(at url: URL?) -> Wake? {
        guard url == self.url else { return nil }
        if let state { return .state(state) }
        return .load(self.url, scrollY: scrollY.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func validScroll(_ y: Double) -> Double? {
        y.isFinite && y >= 0 && y <= 10_000_000 ? y : nil
    }

    // MARK: Format

    /// Written into every place; a file of any other version reads as no place.
    public static let formatVersion = 1

    private struct File: Codable {
        var version: Int
        var url: URL
        var title: String
        var scrollY: Double?
        var state: Data?
    }

    /// A binary property list of at most `limit` bytes: a place too big keeps only its record, and nil when even that
    /// does not fit (a huge `data:` address).
    public func encoded(limit: Int) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func encode(_ place: TabPlace) -> Data? {
            let file = File(
                version: Self.formatVersion, url: place.url, title: place.title, scrollY: place.scrollY,
                state: place.state)
            guard let data = try? encoder.encode(file), data.count <= limit else { return nil }
            return data
        }
        if let data = encode(self) { return data }
        guard state != nil else { return nil }
        var record = self
        record.state = nil
        return encode(record)
    }

    /// The place in `data`; nil when it is over `limit`, unreadable, or of another version.
    public static func decode(_ data: Data, limit: Int) -> TabPlace? {
        guard data.count <= limit, let file = try? PropertyListDecoder().decode(File.self, from: data),
            file.version == formatVersion
        else { return nil }
        return TabPlace(url: file.url, title: file.title, scrollY: file.scrollY, state: file.state, sentForm: false)
    }
}

/// One workspace's tab places, one file per tab, `<tab id>.place` in `directory` (D5). Each file is created owner-only
/// (0600, in a 0700 directory) under a temporary name and renamed into place, so it is never readable by others nor
/// seen half written; each is stamped with when its tab was last seen, and past `totalLimit` the least recently seen
/// go. A place that is missing, too big, unreadable or of another version reads as nil, so the tab loads its address;
/// a bad file is removed. Every call runs on the caller's thread: places are small and capped, the directory is set up
/// once, and the files' sizes are listed once, then kept as they are written and removed, so a write costs no listing.
public final class PlaceStore {
    /// At most this many bytes per tab: a bigger place keeps only its record.
    public static let tabLimit = 256 * 1024
    /// At most this many bytes per workspace.
    public static let totalLimit = 8 * 1024 * 1024
    public static let fileExtension = "place"

    public let directory: URL
    public let tabLimit: Int
    public let totalLimit: Int
    /// The directory exists, owner-only.
    private var isPrepared = false
    /// Each place file's size and when its tab was last seen; nil until first needed, then listed once.
    private var index: [TabID: (size: Int, seen: Date)]?
    private var total = 0

    public init(directory: URL, tabLimit: Int = PlaceStore.tabLimit, totalLimit: Int = PlaceStore.totalLimit) {
        self.directory = directory
        self.tabLimit = tabLimit
        self.totalLimit = totalLimit
    }

    public func url(for tab: TabID) -> URL {
        directory.appending(path: "\(tab.uuidString).\(Self.fileExtension)")
    }

    /// Writes the tab's place, last seen at `seen`, then removes the least recently seen others until the workspace's
    /// places fit `totalLimit`. A place that does not fit `tabLimit` even as a record removes the tab's old one.
    public func write(_ place: TabPlace, for tab: TabID, seen: Date = .now) throws {
        guard let data = place.encoded(limit: tabLimit) else {
            remove(tab)
            return
        }
        do {
            try create(data, at: url(for: tab))
        } catch CocoaError.fileNoSuchFile {
            // The directory went since it was set up: once more from the start.
            isPrepared = false
            index = nil
            try create(data, at: url(for: tab))
        }
        var entries = listed()
        total += data.count - (entries[tab]?.size ?? 0)
        entries[tab] = (data.count, seen)
        index = entries
        // Only the eviction order hangs on the stamp; a file without it still counts, as seen now.
        try? FileManager.default.setAttributes(
            [.modificationDate: seen], ofItemAtPath: url(for: tab).path(percentEncoded: false))
        evict(keeping: tab)
    }

    /// The tab's place; nil when there is none or it cannot be used (that file is removed).
    public func read(_ tab: TabID) -> TabPlace? {
        let file = url(for: tab)
        let path = file.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            forget(tab)
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if let size, size <= tabLimit, let data = try? Data(contentsOf: file),
            let place = TabPlace.decode(data, limit: tabLimit)
        {
            return place
        }
        remove(tab)
        return nil
    }

    /// The tab's place goes; a missing one is fine.
    public func remove(_ tab: TabID) {
        try? FileManager.default.removeItem(at: url(for: tab))
        forget(tab)
    }

    /// Removes every place but those of `tabs` (tabs that closed in a run that could not remove theirs), and any
    /// temporary file a write that never finished left behind.
    public func prune(keeping tabs: Set<TabID>) {
        for tab in listed().keys where !tabs.contains(tab) { remove(tab) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func forget(_ tab: TabID) {
        guard let entry = index?.removeValue(forKey: tab) else { return }
        total -= entry.size
    }

    /// Creates the directory owner-only, once.
    private func prepare() throws {
        guard !isPrepared else { return }
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
        isPrepared = true
    }

    /// Writes `data` to a new 0600 file with a hidden temporary name beside `file`, then renames it over `file`.
    private func create(_ data: Data, at file: URL) throws {
        try prepare()
        let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
        let path = temporary.path(percentEncoded: false)
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(path, file.path(percentEncoded: false)) == 0 else {
            let error = Self.posixError(path)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func posixError(_ path: String) -> any Error {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        if code == .ENOENT { return CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        return POSIXError(code)
    }

    /// The place files' sizes and seen dates, listed from `directory` the first time; anything else there is left
    /// alone.
    private func listed() -> [TabID: (size: Int, seen: Date)] {
        if let index { return index }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        var entries: [TabID: (size: Int, seen: Date)] = [:]
        for url in urls where url.pathExtension == Self.fileExtension {
            guard let tab = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            entries[tab] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        index = entries
        total = entries.values.reduce(0) { $0 + $1.size }
        return entries
    }

    /// Least recently seen first, never `kept`, until the total fits.
    private func evict(keeping kept: TabID) {
        guard total > totalLimit else { return }
        let oldestFirst = listed().filter { $0.key != kept }.sorted {
            $0.value.seen == $1.value.seen ? $0.key.uuidString < $1.key.uuidString : $0.value.seen < $1.value.seen
        }
        for (tab, _) in oldestFirst where total > totalLimit { remove(tab) }
    }
}

/// The main frame's scroll position of one tab, from the work script's place messages (`PageWorkScript.Place`). A
/// document that left (`pagehide`) takes its position with it, so a late report of a page left behind is not taken
/// for the next one.
public struct MainScroll: Equatable, Sendable {
    private var document: String?
    public private(set) var y: Double?

    public init() {}

    public mutating func apply(_ place: PageWorkScript.Place) {
        switch place {
        case .scrolled(let document, let y):
            self.document = document
            self.y = y
        case .left(let document):
            guard document == self.document else { return }
            self.document = nil
            y = nil
        }
    }
}

/// Puts a record's scroll position back once its address loads (D5), from a user script rather than the app's own
/// JavaScript call, which would count as user activation and arm the page's `beforeunload` prompt (S0 item 3).
public enum PlaceScript {
    /// Its own content world, so its script is removed without touching the work script.
    public static let worldName = "lodge.place"

    /// For document end, main frame only: a document at `url` scrolls to `y` now, once loaded and shortly after,
    /// unless the user scrolls, clicks or types first.
    public static func restoreScroll(to y: Double, at url: URL) -> String {
        let address = (try? JSONEncoder().encode(url.absoluteString)).flatMap { String(data: $0, encoding: .utf8) }
        return """
            (() => {
              if (window.top !== window || location.href !== \(address ?? "null")) { return; }
              const y = \(y.isFinite ? y : 0);
              let moved = false;
              const stop = (e) => { if (e.isTrusted) { moved = true; } };
              for (const type of ['wheel', 'mousedown', 'keydown', 'touchstart']) {
                window.addEventListener(type, stop, { capture: true, passive: true });
              }
              const go = () => { if (!moved) { window.scrollTo(0, y); } };
              go();
              window.addEventListener('load', () => { go(); setTimeout(go, 300); }, { once: true });
            })();
            """
    }
}
