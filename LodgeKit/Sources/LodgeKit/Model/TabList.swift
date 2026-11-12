import Foundation

/// A live tab as the browser window shows it; the web view itself lives in the app's registry.
public struct BrowserTab: Identifiable, Hashable, Sendable {
    public let id: TabID
    public var store: StoreRef
    public var url: URL?
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var hasCrashed: Bool
    /// The saved link this tab was opened from, if any.
    public var link: UUID?

    public init(
        id: TabID = TabID(), store: StoreRef = .global, url: URL? = nil, title: String = "", isLoading: Bool = false,
        canGoBack: Bool = false, canGoForward: Bool = false, hasCrashed: Bool = false, link: UUID? = nil
    ) {
        self.id = id
        self.store = store
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasCrashed = hasCrashed
        self.link = link
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = url?.host(), !host.isEmpty { return host }
        return url?.absoluteString ?? "New Tab"
    }
}

/// Ordered tabs of one window and which one is selected.
public struct TabList: Sendable, Equatable {
    public private(set) var tabs: [BrowserTab] = []
    public private(set) var selectedID: TabID?

    public init() {}

    public var selected: BrowserTab? { selectedID.flatMap { self[$0] } }

    public subscript(id: TabID) -> BrowserTab? { tabs.first { $0.id == id } }

    public func tab(forLink link: UUID) -> BrowserTab? { tabs.first { $0.link == link } }

    /// Appends `tab` and selects it.
    public mutating func open(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedID = tab.id
    }

    public mutating func select(_ id: TabID) {
        if self[id] != nil { selectedID = id }
    }

    /// Removes the tab; when it was selected, nothing is selected.
    public mutating func close(_ id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if selectedID == id { selectedID = nil }
        tabs.remove(at: index)
    }

    /// Moves the session from the selected tab to `next`, a tab in the list, or nil for none. The tab
    /// left drops out of the list; a link's tab drops out too, as its row is the saved
    /// link, and returning to that link opens a fresh tab. Moving to the selected tab, or to a tab not
    /// in the list, changes nothing.
    public mutating func leave(to next: TabID?) {
        guard next != selectedID, next.map({ self[$0] != nil }) ?? true else { return }
        if let index = tabs.firstIndex(where: { $0.id == selectedID }) { tabs.remove(at: index) }
        selectedID = next
    }

    /// Applies `change` to the tab; an unknown id changes nothing.
    public mutating func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}
