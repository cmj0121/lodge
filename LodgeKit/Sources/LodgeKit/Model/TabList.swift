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

    public init(
        id: TabID = TabID(), store: StoreRef = .global, url: URL? = nil, title: String = "", isLoading: Bool = false,
        canGoBack: Bool = false, canGoForward: Bool = false, hasCrashed: Bool = false
    ) {
        self.id = id
        self.store = store
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.hasCrashed = hasCrashed
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

    /// Appends `tab`, or inserts it right after `source` when that tab exists. A background open
    /// still selects the tab when nothing else is selected.
    public mutating func open(_ tab: BrowserTab, after source: TabID? = nil, select: Bool = true) {
        if let source, let index = tabs.firstIndex(where: { $0.id == source }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select || selectedID == nil { selectedID = tab.id }
    }

    public mutating func select(_ id: TabID) {
        if self[id] != nil { selectedID = id }
    }

    /// Removes the tab; when it was selected, its right neighbour (or else its left one) is selected.
    public mutating func close(_ id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    public mutating func selectNext() { step(by: 1) }

    public mutating func selectPrevious() { step(by: -1) }

    /// Applies `change` to the tab; an unknown id changes nothing.
    public mutating func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }

    private mutating func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = selectedID, let index = tabs.firstIndex(where: { $0.id == current }) else {
            selectedID = tabs.first?.id
            return
        }
        selectedID = tabs[(index + offset + tabs.count) % tabs.count].id
    }
}
