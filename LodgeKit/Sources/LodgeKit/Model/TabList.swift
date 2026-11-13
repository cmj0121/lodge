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

/// A workspace's open tabs, in order; which one a window shows is the window resolver's (`WindowSelections`).
public struct TabList: Sendable, Equatable {
    public private(set) var tabs: [BrowserTab] = []

    public init() {}

    public init(tabs: [BrowserTab]) {
        self.tabs = tabs
    }

    public subscript(id: TabID) -> BrowserTab? { tabs.first { $0.id == id } }

    public func tab(forLink link: UUID) -> BrowserTab? { tabs.first { $0.link == link } }

    /// Appends `tab`.
    public mutating func open(_ tab: BrowserTab) {
        tabs.append(tab)
    }

    /// Removes `id`; an unknown id changes nothing.
    public mutating func close(_ id: TabID) {
        tabs.removeAll { $0.id == id }
    }

    /// Applies `change` to the tab; an unknown id changes nothing.
    public mutating func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}
