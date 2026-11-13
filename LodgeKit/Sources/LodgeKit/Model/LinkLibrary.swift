import Foundation

/// A link the user kept, with the title it shows under.
public struct SavedLink: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public var title: String
    /// A small PNG of the site's icon, kept only for Anonymous bookmarks (`LinkIcon.png`); nil elsewhere, where
    /// icons load live. Missing in older files.
    public var icon: Data?

    public init(id: UUID = UUID(), url: URL, title: String, icon: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.icon = icon
    }
}

/// Where a saved link is kept: the pinned sites, or the bookmarks.
public enum LinkShelf: CaseIterable, Sendable {
    case pins
    case bookmarks
}

/// The user's pins and bookmarks. Pins are a flat shelf in the user's order; bookmarks are a tree of folders
/// under one root folder, each folder in the user's order. Links are appended as they are added and can be
/// moved. The default library is empty; it is persisted through the session snapshot.
public struct LinkLibrary: Equatable, Sendable {
    private var pins: [SavedLink]
    /// The root folder; it is never removed or moved.
    public private(set) var bookmarks: BookmarkFolder

    public init(
        pins: [SavedLink] = [], bookmarks: BookmarkFolder = BookmarkFolder(title: "Bookmarks", isExpanded: true)
    ) {
        self.pins = pins
        self.bookmarks = bookmarks
    }

    /// A library whose bookmarks all sit in the root folder, in `bookmarks` order.
    public init(pins: [SavedLink], bookmarks: [SavedLink]) {
        self.init(
            pins: pins,
            bookmarks: BookmarkFolder(title: "Bookmarks", isExpanded: true, children: bookmarks.map(BookmarkNode.link)))
    }

    /// A library with a few well-known sites, for previews and the mock UI.
    public static let sample = LinkLibrary(
        pins: [
            SavedLink(url: URL(string: "https://www.apple.com")!, title: "Apple"),
            SavedLink(url: URL(string: "https://github.com")!, title: "GitHub"),
            SavedLink(url: URL(string: "https://www.wikipedia.org")!, title: "Wikipedia"),
            SavedLink(url: URL(string: "https://duckduckgo.com")!, title: "DuckDuckGo"),
        ],
        bookmarks: BookmarkFolder(
            title: "Bookmarks", isExpanded: true,
            children: [
                .link(SavedLink(url: URL(string: "https://developer.apple.com/documentation/swift")!, title: "Swift")),
                .link(SavedLink(url: URL(string: "https://news.ycombinator.com")!, title: "Hacker News")),
                .link(SavedLink(url: URL(string: "https://developer.mozilla.org")!, title: "MDN Web Docs")),
                .folder(
                    BookmarkFolder(
                        title: "Reading",
                        children: [
                            .link(SavedLink(url: URL(string: "https://www.swift.org/blog/")!, title: "Swift Blog"))
                        ])),
            ])
    )

    /// The shelf's links in order; for bookmarks, every link of the tree depth-first.
    public func links(on shelf: LinkShelf) -> [SavedLink] {
        switch shelf {
        case .pins: pins
        case .bookmarks: bookmarks.links
        }
    }

    /// Appends `url` to `shelf` and returns the new link; bookmarks go into the root folder. A URL already on
    /// the pins, or directly in the root folder, is not added again; the link already there is returned unchanged.
    @discardableResult public mutating func add(_ url: URL, title: String, to shelf: LinkShelf) -> SavedLink {
        switch shelf {
        case .pins:
            if let existing = pins.first(where: { $0.url == url }) { return existing }
            let link = SavedLink(url: url, title: title)
            pins.append(link)
            return link
        case .bookmarks:
            return addBookmark(url, title: title, in: bookmarks.id)!
        }
    }

    /// Appends a bookmark of `url` to the folder and returns it; a URL already directly in that folder is not
    /// added again and the link already there is returned. Nil for an unknown folder.
    @discardableResult public mutating func addBookmark(_ url: URL, title: String, in folder: UUID) -> SavedLink? {
        bookmarks.update(folder) { folder in
            for case .link(let existing) in folder.children where existing.url == url { return existing }
            let link = SavedLink(url: url, title: title)
            folder.children.append(.link(link))
            return link
        }
    }

    /// Adds an empty, collapsed folder to `parent` at `index` (clamped to 0...count; nil appends) and returns it;
    /// nil for an unknown parent.
    @discardableResult
    public mutating func addFolder(_ title: String, in parent: UUID, at index: Int? = nil) -> BookmarkFolder? {
        let folder = BookmarkFolder(title: title)
        return bookmarks.update(parent) { parent in
            let count = parent.children.count
            parent.children.insert(.folder(folder), at: index.map { min(max($0, 0), count) } ?? count)
            return folder
        }
    }

    /// Appends `folder` with everything in it to `parent`; an unknown parent changes nothing.
    public mutating func insert(_ folder: BookmarkFolder, in parent: UUID) {
        bookmarks.update(parent) { $0.children.append(.folder(folder)) }
    }

    /// Retitles the folder or bookmark with `id`; the root folder, pins and unknown ids are left as they are.
    public mutating func rename(_ id: UUID, to title: String) {
        guard let parent = parent(of: id) else { return }
        bookmarks.update(parent) { parent in
            guard let index = parent.children.firstIndex(where: { $0.id == id }) else { return }
            switch parent.children[index] {
            case .link(var link):
                link.title = title
                parent.children[index] = .link(link)
            case .folder(var folder):
                folder.title = title
                parent.children[index] = .folder(folder)
            }
        }
    }

    /// Sets the icon of the pin or bookmark with `id`; folders and unknown ids are left as they are.
    public mutating func setIcon(_ id: UUID, _ icon: Data?) {
        if let index = pins.firstIndex(where: { $0.id == id }) {
            pins[index].icon = icon
            return
        }
        guard let parent = parent(of: id) else { return }
        bookmarks.update(parent) { parent in
            guard let index = parent.children.firstIndex(where: { $0.id == id }),
                case .link(var link) = parent.children[index]
            else { return }
            link.icon = icon
            parent.children[index] = .link(link)
        }
    }

    /// Removes the pin, bookmark or folder with `id`, a folder with everything in it, and returns the ids of
    /// every link removed. The root folder and unknown ids change nothing and return [].
    @discardableResult public mutating func remove(_ id: UUID) -> [UUID] {
        if let index = pins.firstIndex(where: { $0.id == id }) { return [pins.remove(at: index).id] }
        guard let parent = parent(of: id) else { return [] }
        return bookmarks.update(parent) { parent in
            guard let index = parent.children.firstIndex(where: { $0.id == id }) else { return [] }
            return parent.children.remove(at: index).linkIDs
        } ?? []
    }

    /// Whether bookmark or folder `id` can move into `folder`: false for the root, a pin, unknown ids, a target
    /// that is no folder, and a folder into itself or one of its descendants.
    public func canMoveBookmark(_ id: UUID, into folder: UUID) -> Bool {
        guard parent(of: id) != nil, bookmarks.folder(folder) != nil else { return false }
        return self.folder(id)?.folder(folder) == nil
    }

    /// Moves bookmark or folder `id` into `folder` at `index`, counted among the folder's children as they are
    /// before the move and clamped to 0...count; nil appends. Moving down within the same folder lands just
    /// before what was at `index`. Returns false and changes nothing when `canMoveBookmark` is false.
    @discardableResult public mutating func moveBookmark(_ id: UUID, into folder: UUID, at index: Int?) -> Bool {
        guard canMoveBookmark(id, into: folder), let source = parent(of: id),
            let from = bookmarks.folder(source)?.children.firstIndex(where: { $0.id == id }),
            let count = bookmarks.folder(folder)?.children.count
        else { return false }
        var target = index.map { min(max($0, 0), count) }
        if source == folder, let to = target, from < to { target = to - 1 }
        let node = bookmarks.update(source) { $0.children.remove(at: from) }!
        bookmarks.update(folder) { $0.children.insert(node, at: target ?? $0.children.count) }
        return true
    }

    /// Moves pin `id` so it ends at `index` of the pins (clamped to 0...count-1); an unknown id changes nothing.
    public mutating func move(_ id: UUID, to index: Int) {
        guard let from = pins.firstIndex(where: { $0.id == id }) else { return }
        let link = pins.remove(at: from)
        pins.insert(link, at: min(max(index, 0), pins.count))
    }

    /// Opens or closes the folder; an unknown id changes nothing.
    public mutating func setExpanded(_ folder: UUID, _ expanded: Bool) {
        bookmarks.update(folder) { $0.isExpanded = expanded }
    }

    /// Opens every folder above the bookmark `link`, so its row shows; a link outside the bookmarks changes nothing.
    public mutating func reveal(_ link: UUID) {
        for folder in bookmarks.path(to: link) ?? [] { setExpanded(folder, true) }
    }

    /// The folder with `id`, the root included.
    public func folder(_ id: UUID) -> BookmarkFolder? { bookmarks.folder(id) }

    /// The folder directly holding bookmark or folder `id`; nil for the root, pins and unknown ids.
    public func parent(of id: UUID) -> UUID? { bookmarks.path(to: id)?.last }
}
