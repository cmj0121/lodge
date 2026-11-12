import Foundation

/// One sidebar entry: a saved link on its shelf with its open tab, if any, or a loose tab.
public enum SidebarItem: Identifiable, Equatable, Sendable {
    case link(SavedLink, LinkShelf, BrowserTab?)
    case tab(BrowserTab)

    public enum ID: Hashable, Sendable {
        case link(UUID)
        case tab(TabID)
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

/// The sidebar's entries: each pin and bookmark with its open tab, if any, and the loose tabs.
public struct SidebarSections: Equatable, Sendable {
    public private(set) var pins: [SidebarItem] = []
    public private(set) var bookmarks: [SidebarItem] = []
    /// Tabs no link holds, in tab order: loose tabs, a tab whose link was removed, and any tab past
    /// the first one of the same link.
    public private(set) var loose: [SidebarItem] = []

    public init() {}

    public init(pins: [SavedLink], bookmarks: [SavedLink], tabs: TabList) {
        self.pins = pins.map { .link($0, .pins, tabs.tab(forLink: $0.id)) }
        self.bookmarks = bookmarks.map { .link($0, .bookmarks, tabs.tab(forLink: $0.id)) }
        let paired = Set((self.pins + self.bookmarks).compactMap(\.tab?.id))
        loose = tabs.tabs.filter { !paired.contains($0.id) }.map(SidebarItem.tab)
    }

    /// Where an entry leads: its open tab, or the saved link to open.
    public enum Target: Equatable, Sendable {
        case tab(TabID)
        case link(SavedLink)
    }

    /// The entry `offset` entries away from the one holding `tab`, in sidebar order (pins, bookmarks,
    /// loose tabs), wrapping around. From no tab, or one no entry holds, a forward step lands on the
    /// first entry and a backward one on the last. Nil when there are no entries.
    public func target(_ offset: Int, from tab: TabID?) -> Target? {
        let targets = (pins + bookmarks + loose).map(\.target)
        guard !targets.isEmpty else { return nil }
        guard let tab, let index = targets.firstIndex(of: .tab(tab)) else {
            return offset > 0 ? targets.first : targets.last
        }
        let count = targets.count
        return targets[((index + offset) % count + count) % count]
    }

    /// The open tab to select after `tab` closes: the next entry holding an open tab in sidebar order
    /// (pins, bookmarks, loose), skipping links with no tab; else the previous one; nil when `tab` is the only one.
    public func neighbour(ofClosing tab: TabID) -> TabID? {
        let open = (pins + bookmarks + loose).compactMap(\.tab?.id)
        guard let index = open.firstIndex(of: tab) else { return nil }
        if index + 1 < open.count { return open[index + 1] }
        return index > 0 ? open[index - 1] : nil
    }
}
