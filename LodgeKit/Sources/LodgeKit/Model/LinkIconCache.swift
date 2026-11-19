import Foundation

/// One workspace's kept pin and bookmark icons, one PNG per link (`LinkIcon` bytes), `<link id>.png` in `directory`
/// (D2). A local cache beside the workspace's other files, never part of the session file: removing a link removes
/// its file, and deleting the workspace's directory removes them all. Each link's file is read at most once, the first
/// time its icon is asked for, and its bytes are then remembered, as are those written, so a write compares in memory.
/// Every call but `prune` runs on the caller's thread; icons are small and capped. A file that is unreadable or not a
/// valid icon reads as none and is removed.
public final class LinkIconCache {
    public static let fileExtension = "png"

    public let directory: URL
    /// The directory exists, owner-only.
    private var isPrepared = false
    /// Each link's kept bytes as last read or written; a link with no entry has not been read yet, one mapped to nil
    /// keeps no icon.
    private var known: [UUID: Data?] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    public func url(for link: UUID) -> URL {
        Self.url(for: link, in: directory)
    }

    private static func url(for link: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(link.uuidString).\(fileExtension)")
    }

    /// The link's kept icon, read from disk only the first time; nil when there is none or its file is not a valid
    /// icon (that file is removed).
    public func icon(for link: UUID) -> Data? {
        if let entry = known[link] { return entry }
        let file = url(for: link)
        var data: Data?
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            data = (try? Data(contentsOf: file)).flatMap { LinkIcon.isValid($0) ? $0 : nil }
            if data == nil { try? FileManager.default.removeItem(at: file) }
        }
        known[link] = .some(data)
        return data
    }

    /// Keeps `data` as the link's icon, writing only when it differs from the bytes kept (`icon(for:)`). Bytes that
    /// are not a valid icon are refused. Returns whether a file was written.
    @discardableResult
    public func write(_ data: Data, for link: UUID) throws -> Bool {
        guard LinkIcon.isValid(data), icon(for: link) != data else { return false }
        try prepare()
        do {
            try data.write(to: url(for: link), options: .atomic)
        } catch CocoaError.fileNoSuchFile {
            // The directory went since it was set up: once more from the start.
            isPrepared = false
            try prepare()
            try data.write(to: url(for: link), options: .atomic)
        }
        known[link] = .some(data)
        return true
    }

    /// The link's icon goes; a missing one is fine.
    public func remove(_ link: UUID) {
        try? FileManager.default.removeItem(at: url(for: link))
        known[link] = .some(nil)
    }

    /// Removes from `directory` every icon but those of `links` (links removed in a run that could not remove theirs)
    /// last written before `cutoff`, so an icon kept after the list of links was taken stays. Touches only the files,
    /// never creating the directory, so it can run off the main actor while the workspace is used or deleted.
    public static func prune(_ directory: URL, keeping links: Set<UUID>, before cutoff: Date) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name.hasSuffix(".\(fileExtension)") {
            guard let link = UUID(uuidString: String(name.dropLast(fileExtension.count + 1))), !links.contains(link)
            else { continue }
            let file = url(for: link, in: directory)
            let modified = (try? manager.attributesOfItem(atPath: file.path(percentEncoded: false)))?[
                .modificationDate] as? Date
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: file)
        }
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
}

/// Whether a link's tab is on that link's own load (D2): the page its URL lands on, server and in-load redirects
/// included, is the only page whose icon the link keeps. The browser starting the load of the link's URL marks it;
/// the first main-frame navigation that is not that load or a redirect of it (a link click, a typed address,
/// back/forward, a reload, a script navigating once the page has loaded) clears it for good.
public struct LinkOwnLoad: Equatable, Sendable {
    /// The tab's page is its link's own: an icon arriving now is kept.
    public private(set) var isOn = false
    /// The own load is asked for and its first main-frame navigation action has not come yet.
    private var awaitsAction = false
    /// The own load has not ended yet, so a main-frame action of type "other" is one of its redirects.
    private var isLoading = false

    public init() {}

    /// The browser is about to load the link's own URL in the tab.
    public mutating func start() {
        isOn = true
        awaitsAction = true
        isLoading = true
    }

    /// A main-frame navigation action; `isOther` when WebKit gives it no type (a redirect, a script's navigation).
    public mutating func navigationAction(isOther: Bool) {
        if awaitsAction {
            awaitsAction = false
        } else if !(isLoading && isOther) {
            isOn = false
            isLoading = false
        }
    }

    /// The main frame's load finished, failed or stopped: from now on every navigation leaves the own page.
    public mutating func loadEnded() {
        guard !awaitsAction else { return }
        isLoading = false
    }
}
