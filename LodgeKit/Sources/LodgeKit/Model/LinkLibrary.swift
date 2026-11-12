import Foundation

/// A link the user kept, with the title it shows under.
public struct SavedLink: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String

    public init(id: UUID = UUID(), url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}

/// Where a saved link is kept: the pinned sites, or the bookmarks.
public enum LinkShelf: CaseIterable, Sendable {
    case pins
    case bookmarks
}

/// The user's pins and bookmarks, each shelf in the user's order: links are appended as they are added and can
/// be moved within their shelf. The default library is empty; it is persisted through the session snapshot.
public struct LinkLibrary: Equatable, Sendable {
    private var shelves: [LinkShelf: [SavedLink]]

    public init(pins: [SavedLink] = [], bookmarks: [SavedLink] = []) {
        shelves = [.pins: pins, .bookmarks: bookmarks]
    }

    /// A library with a few well-known sites, for previews and the mock UI.
    public static let sample = LinkLibrary(
        pins: [
            SavedLink(url: URL(string: "https://www.apple.com")!, title: "Apple"),
            SavedLink(url: URL(string: "https://github.com")!, title: "GitHub"),
            SavedLink(url: URL(string: "https://www.wikipedia.org")!, title: "Wikipedia"),
            SavedLink(url: URL(string: "https://duckduckgo.com")!, title: "DuckDuckGo"),
        ],
        bookmarks: [
            SavedLink(url: URL(string: "https://developer.apple.com/documentation/swift")!, title: "Swift"),
            SavedLink(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News"),
            SavedLink(url: URL(string: "https://developer.mozilla.org")!, title: "MDN Web Docs"),
        ]
    )

    public func links(on shelf: LinkShelf) -> [SavedLink] { shelves[shelf, default: []] }

    /// Appends `url` to `shelf` and returns the new link. A URL already on that shelf is not added again; the
    /// link already there is returned unchanged.
    @discardableResult public mutating func add(_ url: URL, title: String, to shelf: LinkShelf) -> SavedLink {
        if let existing = links(on: shelf).first(where: { $0.url == url }) { return existing }
        let link = SavedLink(url: url, title: title)
        shelves[shelf, default: []].append(link)
        return link
    }

    /// Removes the link with `id` from whichever shelf holds it; an unknown id changes nothing.
    public mutating func remove(_ id: UUID) {
        for shelf in LinkShelf.allCases {
            shelves[shelf]?.removeAll { $0.id == id }
        }
    }

    /// Moves link `id` within its shelf so it ends at `index` of that shelf (clamped to 0...count-1); an unknown
    /// id changes nothing.
    public mutating func move(_ id: UUID, to index: Int) {
        for shelf in LinkShelf.allCases {
            guard var links = shelves[shelf], let from = links.firstIndex(where: { $0.id == id }) else { continue }
            let link = links.remove(at: from)
            links.insert(link, at: min(max(index, 0), links.count))
            shelves[shelf] = links
            return
        }
    }
}
