import Foundation

/// A bookmark folder: a titled, ordered list of bookmarks and sub-folders, shown open or closed in the sidebar.
public struct BookmarkFolder: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var isExpanded: Bool
    public var children: [BookmarkNode]

    public init(id: UUID = UUID(), title: String, isExpanded: Bool = false, children: [BookmarkNode] = []) {
        self.id = id
        self.title = title
        self.isExpanded = isExpanded
        self.children = children
    }

    /// Every link in the folder, depth-first in child order.
    var links: [SavedLink] {
        children.flatMap { node -> [SavedLink] in
            switch node {
            case .link(let link): [link]
            case .folder(let folder): folder.links
            }
        }
    }

    /// The folder with `change` applied to every link in it, at any depth.
    func mappingLinks(_ change: (inout SavedLink) -> Void) -> BookmarkFolder {
        var folder = self
        folder.children = children.map { node in
            switch node {
            case .link(var link):
                change(&link)
                return .link(link)
            case .folder(let child):
                return .folder(child.mappingLinks(change))
            }
        }
        return folder
    }

    /// The folder with `id`: this one or one anywhere below it.
    func folder(_ id: UUID) -> BookmarkFolder? {
        if self.id == id { return self }
        for case .folder(let child) in children {
            if let found = child.folder(id) { return found }
        }
        return nil
    }

    /// The ids of the folders from this one down to the one directly holding `id`; nil when nothing below
    /// this folder has that id.
    func path(to id: UUID) -> [UUID]? {
        for node in children {
            if node.id == id { return [self.id] }
            if case .folder(let child) = node, let path = child.path(to: id) { return [self.id] + path }
        }
        return nil
    }

    /// Runs `body` on the folder with `id`, this one or one below it; nil when there is none.
    @discardableResult mutating func update<R>(_ id: UUID, _ body: (inout BookmarkFolder) -> R) -> R? {
        if self.id == id { return body(&self) }
        for index in children.indices {
            guard case .folder(var child) = children[index] else { continue }
            if let result = child.update(id, body) {
                children[index] = .folder(child)
                return result
            }
        }
        return nil
    }
}

/// One entry of a bookmark folder: a bookmark or a sub-folder.
public enum BookmarkNode: Identifiable, Hashable, Codable, Sendable {
    case link(SavedLink)
    case folder(BookmarkFolder)

    public var id: UUID {
        switch self {
        case .link(let link): link.id
        case .folder(let folder): folder.id
        }
    }

    /// The ids of every link in the node: itself, or all a folder holds.
    var linkIDs: [UUID] {
        switch self {
        case .link(let link): [link.id]
        case .folder(let folder): folder.links.map(\.id)
        }
    }

    private enum Kind: String, Codable {
        case link
        case folder
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, url, title, icon, isExpanded, children
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .link:
            self = .link(
                SavedLink(
                    id: id, url: try container.decode(URL.self, forKey: .url), title: title,
                    icon: try container.decodeIfPresent(Data.self, forKey: .icon)))
        case .folder:
            self = .folder(
                BookmarkFolder(
                    id: id, title: title, isExpanded: try container.decode(Bool.self, forKey: .isExpanded),
                    children: try container.decode([BookmarkNode].self, forKey: .children)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .link(let link):
            try container.encode(Kind.link, forKey: .kind)
            try container.encode(link.id, forKey: .id)
            try container.encode(link.url, forKey: .url)
            try container.encode(link.title, forKey: .title)
            try container.encodeIfPresent(link.icon, forKey: .icon)
        case .folder(let folder):
            try container.encode(Kind.folder, forKey: .kind)
            try container.encode(folder.id, forKey: .id)
            try container.encode(folder.title, forKey: .title)
            try container.encode(folder.isExpanded, forKey: .isExpanded)
            try container.encode(folder.children, forKey: .children)
        }
    }
}
