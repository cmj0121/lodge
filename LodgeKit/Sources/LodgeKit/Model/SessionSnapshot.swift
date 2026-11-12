import Foundation

/// What the window keeps across launches: the tabs in order, the selected tab, the pins and the bookmarks.
/// Runtime state (loading, history buttons, crashes, progress, favicons, security) is not stored.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Tab: Codable, Equatable, Sendable {
        public var id: TabID
        public var store: StoreRef
        /// Nil for a blank tab.
        public var url: URL?
        public var title: String
        public var link: UUID?
    }

    public enum DecodeError: Error, Equatable {
        /// Written by a newer Lodge.
        case unsupportedVersion(Int)
    }

    /// `currentVersion` when written.
    public var version: Int
    /// In `TabList` order.
    public var tabs: [Tab]
    public var selectedTab: TabID?
    /// In shelf order.
    public var pins: [SavedLink]
    public var bookmarks: [SavedLink]

    public init(tabs: TabList, library: LinkLibrary) {
        version = Self.currentVersion
        self.tabs = tabs.tabs.map { Tab(id: $0.id, store: $0.store, url: $0.url, title: $0.title, link: $0.link) }
        selectedTab = tabs.selectedID
        pins = library.links(on: .pins)
        bookmarks = library.links(on: .bookmarks)
    }

    /// Restored state: every tab `isLive == false`; a `link` naming no saved link is dropped (tab loose);
    /// an unknown/absent `selectedTab` falls to the first tab; empty `tabs` → empty TabList.
    public func restored() -> (tabs: TabList, library: LinkLibrary) {
        let links = Set((pins + bookmarks).map(\.id))
        let restored = tabs.map {
            BrowserTab(
                id: $0.id, store: $0.store, url: $0.url, title: $0.title,
                link: $0.link.flatMap { links.contains($0) ? $0 : nil }, isLive: false)
        }
        return (TabList(tabs: restored, selectedID: selectedTab), LinkLibrary(pins: pins, bookmarks: bookmarks))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Throws `SessionSnapshot.DecodeError.unsupportedVersion(Int)` for `version > currentVersion`.
    public static func decode(_ data: Data) throws -> SessionSnapshot {
        let decoder = JSONDecoder()
        // The version is read alone first, so a newer file is reported as such rather than as malformed.
        let version = try decoder.decode(Version.self, from: data).version
        guard version <= currentVersion else { throw DecodeError.unsupportedVersion(version) }
        return try decoder.decode(SessionSnapshot.self, from: data)
    }

    private struct Version: Decodable {
        var version: Int
    }
}
