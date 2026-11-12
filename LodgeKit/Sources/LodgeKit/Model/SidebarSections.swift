import Foundation

/// One sidebar entry: a saved link on its shelf with its open tab, if any, or a loose tab.
public enum SidebarItem: Identifiable, Equatable, Sendable {
    case link(SavedLink, LinkShelf, BrowserTab?)
    case tab(BrowserTab)

    public enum ID: Hashable, Sendable {
        case link(UUID)
        case tab(TabID)
        case folder(UUID)
    }

    public var id: ID {
        switch self {
        case .link(let link, _, _): .link(link.id)
        case .tab(let tab): .tab(tab.id)
        }
    }

    public var tab: BrowserTab? {
        switch self {
        case .link(_, _, let tab): tab
        case .tab(let tab): tab
        }
    }

    public var title: String {
        switch self {
        case .link(let link, _, _): link.title
        case .tab(let tab): tab.displayTitle
        }
    }

    public var address: String {
        switch self {
        case .link(let link, _, let tab): (tab?.url ?? link.url).absoluteString
        case .tab(let tab): tab.url?.absoluteString ?? tab.displayTitle
        }
    }

    /// Where activating the item leads: its open tab, else the saved link to open.
    public var target: SidebarSections.Target {
        switch self {
        case .link(let link, _, let tab): tab.map { .tab($0.id) } ?? .link(link)
        case .tab(let tab): .tab(tab.id)
        }
    }

    public func isSelected(_ selected: TabID?) -> Bool {
        tab.map { $0.id == selected } ?? false
    }
}

/// One row of the sidebar's bookmark tree: a folder with its rows, or a bookmark with its open tab, if any.
public indirect enum SidebarNode: Identifiable, Equatable, Sendable {
    case folder(id: UUID, title: String, isExpanded: Bool, children: [SidebarNode])
    case item(SidebarItem)

    public var id: SidebarItem.ID {
        switch self {
        case .folder(let id, _, _, _): .folder(id)
        case .item(let item): item.id
        }
    }

    /// The node's bookmarks depth-first; without `includingCollapsed`, a closed folder
    /// gives only those holding an open tab.
    func items(includingCollapsed: Bool) -> [SidebarItem] {
        switch self {
        case .item(let item): [item]
        case .folder(_, _, let isExpanded, let children):
            children.flatMap { child in
                let items = child.items(includingCollapsed: includingCollapsed)
                return isExpanded || includingCollapsed ? items : items.filter { $0.tab != nil }
            }
        }
    }
}

/// The sidebar's entries: each pin and bookmark with its open tab, if any, and the loose tabs.
public struct SidebarSections: Equatable, Sendable {
    public private(set) var pins: [SidebarItem] = []
    /// The root folder's children.
    public private(set) var bookmarks: [SidebarNode] = []
    /// Tabs no link holds, in tab order: loose tabs, a tab whose link was removed, and any tab past
    /// the first one of the same link.
    public private(set) var loose: [SidebarItem] = []

    public init() {}

    public init(pins: [SavedLink], bookmarks: BookmarkFolder, tabs: TabList) {
        var firstTab: [UUID: BrowserTab] = [:]
        for tab in tabs.tabs {
            if let link = tab.link, firstTab[link] == nil { firstTab[link] = tab }
        }
        func sidebarNode(_ node: BookmarkNode) -> SidebarNode {
            switch node {
            case .link(let link): .item(.link(link, .bookmarks, firstTab[link.id]))
            case .folder(let folder):
                .folder(
                    id: folder.id, title: folder.title, isExpanded: folder.isExpanded,
                    children: folder.children.map(sidebarNode))
            }
        }
        self.pins = pins.map { .link($0, .pins, firstTab[$0.id]) }
        self.bookmarks = bookmarks.children.map(sidebarNode)
        let paired = Set((self.pins + bookmarkItems(includingCollapsed: true)).compactMap(\.tab?.id))
        loose = tabs.tabs.filter { !paired.contains($0.id) }.map(SidebarItem.tab)
    }

    private func bookmarkItems(includingCollapsed: Bool) -> [SidebarItem] {
        bookmarks.flatMap { $0.items(includingCollapsed: includingCollapsed) }
    }

    /// Where an entry leads: its open tab, or the saved link to open.
    public enum Target: Equatable, Sendable {
        case tab(TabID)
        case link(SavedLink)
    }

    /// The entry `offset` entries away from the one holding `tab`, in sidebar order (pins, bookmarks
    /// depth-first, loose tabs), wrapping around. A bookmark inside a closed folder counts only while it
    /// has an open tab. From no tab, or one no entry holds, a forward step lands on the first entry and a
    /// backward one on the last. Nil when there are no entries.
    public func target(_ offset: Int, from tab: TabID?) -> Target? {
        let targets = (pins + bookmarkItems(includingCollapsed: false) + loose).map(\.target)
        guard !targets.isEmpty else { return nil }
        guard let tab, let index = targets.firstIndex(of: .tab(tab)) else {
            return offset > 0 ? targets.first : targets.last
        }
        let count = targets.count
        return targets[((index + offset) % count + count) % count]
    }

    /// The open tab to select after `tab` closes: the next entry holding an open tab in sidebar order
    /// (pins, bookmarks depth-first in every folder, loose), skipping links with no tab; else the previous
    /// one; nil when `tab` is the only one.
    public func neighbour(ofClosing tab: TabID) -> TabID? {
        let open = (pins + bookmarkItems(includingCollapsed: true) + loose).compactMap(\.tab?.id)
        guard let index = open.firstIndex(of: tab) else { return nil }
        if index + 1 < open.count { return open[index + 1] }
        return index > 0 ? open[index - 1] : nil
    }
}
