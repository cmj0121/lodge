import Foundation

/// A tab as the browser window shows it; its web view, while it has one, lives in the app's registry.
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
    /// Whether the tab has a web view; a restored tab has none until it is first selected.
    public var isLive: Bool

    public init(
        id: TabID = TabID(), store: StoreRef = .global, url: URL? = nil, title: String = "", isLoading: Bool = false,
        canGoBack: Bool = false, canGoForward: Bool = false, hasCrashed: Bool = false, link: UUID? = nil,
        isLive: Bool = true
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
        self.isLive = isLive
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

    /// Restores `tabs`, selecting `selectedID` when it is one of them, else the first tab.
    public init(tabs: [BrowserTab], selectedID: TabID?) {
        self.tabs = tabs
        self.selectedID = tabs.contains { $0.id == selectedID } ? selectedID : tabs.first?.id
    }

    public var selected: BrowserTab? { selectedID.flatMap { self[$0] } }

    public subscript(id: TabID) -> BrowserTab? { tabs.first { $0.id == id } }

    public func tab(forLink link: UUID) -> BrowserTab? { tabs.first { $0.link == link } }

    /// Appends `tab` and selects it.
    public mutating func open(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedID = tab.id
    }

    /// Selects the tab, keeping every tab open; an unknown id changes nothing.
    public mutating func select(_ id: TabID) {
        if self[id] != nil { selectedID = id }
    }

    /// Removes `id`. When it was selected, selects `next` if it is in the list, else nothing.
    /// Closing a non-selected tab keeps the selection.
    public mutating func close(_ id: TabID, selecting next: TabID?) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id { selectedID = next.flatMap { self[$0]?.id } }
    }

    /// Applies `change` to the tab; an unknown id changes nothing.
    public mutating func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}
