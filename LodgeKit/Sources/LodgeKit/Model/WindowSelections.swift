import Foundation

public typealias WindowID = UUID

/// One workspace's open tabs as the window resolver sees them.
public struct WorkspaceTabs: Equatable, Sendable {
    public var workspace: UUID
    /// Every open tab, in `SidebarSections.tabOrder`.
    public var order: [TabID]
    /// Tabs with no URL that are not loading.
    public var blank: Set<TabID>

    public init(workspace: UUID, order: [TabID], blank: Set<TabID>) {
        self.workspace = workspace
        self.order = order
        self.blank = blank
    }
}

/// What the caller applies after a resolver call.
public struct SelectionChange: Equatable, Sendable {
    /// Blank tabs to append, unloaded, to the active workspace before showing.
    public var create: [TabID]
    /// Tabs to close in the workspace the call names (`enter`: `leaving`; `removeWindow`: the active one).
    public var close: [TabID]

    public init(create: [TabID] = [], close: [TabID] = []) {
        self.create = create
        self.close = close
    }
}

public enum SelectOutcome: Equatable, Sendable {
    case selected
    case shownIn(WindowID)
    case unknown
}

public struct WindowSelection: Equatable, Sendable {
    public let id: WindowID
    /// The last tab per workspace; the active workspace's is the one shown now. Runtime only.
    public var remembered: [UUID: TabID]
    /// Blanks made for this window on entering a workspace or opening it; closed when it leaves or closes, if
    /// still blank and shown by no other window.
    public var ownedBlanks: Set<TabID>
}

/// Which tab each browser window shows. Every window is on the active workspace, each shows one of its open tabs,
/// and no tab is shown by two windows (D3, D5, D9).
public struct WindowSelections: Equatable, Sendable {
    public private(set) var active: UUID
    /// The key window first.
    public private(set) var windows: [WindowSelection] = []

    public init(active: UUID) {
        self.active = active
    }

    public func shown(in window: WindowID) -> TabID? {
        windows.first { $0.id == window }?.remembered[active]
    }

    public func window(showing tab: TabID) -> WindowID? {
        windows.first { $0.remembered[active] == tab }?.id
    }

    public var shownTabs: Set<TabID> {
        Set(windows.compactMap { $0.remembered[active] })
    }

    /// The first window, key first, remembering a tab in `workspace`.
    public func remembered(in workspace: UUID) -> TabID? {
        windows.lazy.compactMap { $0.remembered[workspace] }.first
    }

    public mutating func makeKey(_ window: WindowID) {
        guard let index = index(of: window) else { return }
        windows.insert(windows.remove(at: index), at: 0)
    }

    /// Launch (D8): windows in snapshot order on `tabs.workspace`. Every window first takes its `selectedTab` (open,
    /// and not an earlier window's), then window 0 still without one takes `fallback` if no window holds it, then
    /// the rest go by D3.
    public mutating func restore(
        _ windows: [(id: WindowID, selectedTab: TabID?)], fallback: TabID?, in tabs: WorkspaceTabs,
        newTab: () -> TabID = { TabID() }
    ) -> SelectionChange {
        active = tabs.workspace
        self.windows = windows.map { WindowSelection(id: $0.id, remembered: [:], ownedBlanks: []) }
        let open = Set(tabs.order)
        var taken: Set<TabID> = []
        func give(_ tab: TabID?, to index: Int) {
            guard let tab, open.contains(tab), self.windows[index].remembered[active] == nil,
                taken.insert(tab).inserted
            else { return }
            self.windows[index].remembered[active] = tab
        }
        for (index, window) in windows.enumerated() { give(window.selectedTab, to: index) }
        if !windows.isEmpty { give(fallback, to: 0) }
        var change = SelectionChange()
        for index in self.windows.indices where self.windows[index].remembered[active] == nil {
            let tab = take(from: tabs, taken: taken, window: index, change: &change, newTab: newTab)
            taken.insert(tab)
            self.windows[index].remembered[active] = tab
        }
        return change
    }

    /// D1/D5: a new window at the front, showing a new blank it owns.
    public mutating func addWindow(_ id: WindowID, newTab: () -> TabID = { TabID() }) -> SelectionChange {
        let tab = newTab()
        windows.insert(WindowSelection(id: id, remembered: [active: tab], ownedBlanks: [tab]), at: 0)
        return SelectionChange(create: [tab])
    }

    /// D5: drops the window; its owned blanks still blank and shown by no other window close.
    public mutating func removeWindow(_ id: WindowID, in tabs: WorkspaceTabs) -> SelectionChange {
        guard let index = index(of: id) else { return SelectionChange() }
        let window = windows.remove(at: index)
        let shown = shownTabs
        let close = tabs.order.filter { window.ownedBlanks.contains($0) && tabs.blank.contains($0) && !shown.contains($0) }
        return SelectionChange(close: close)
    }

    /// Every window leaves `leaving` (the active workspace), its owned blanks still blank closing, then key first
    /// each takes on `target` its remembered tab if open and untaken, else the first untaken in `order`, else a new
    /// blank it owns.
    public mutating func enter(
        _ target: WorkspaceTabs, leaving: WorkspaceTabs, newTab: () -> TabID = { TabID() }
    ) -> SelectionChange {
        guard target.workspace != active else { return SelectionChange() }
        let owned = windows.reduce(into: Set<TabID>()) { $0.formUnion($1.ownedBlanks) }
        let close = leaving.order.filter { owned.contains($0) && leaving.blank.contains($0) }
        let closed = Set(close)
        var change = SelectionChange(close: close)
        for index in windows.indices {
            windows[index].ownedBlanks = []
            if let tab = windows[index].remembered[leaving.workspace], closed.contains(tab) {
                windows[index].remembered[leaving.workspace] = nil
            }
        }
        active = target.workspace
        let open = Set(target.order)
        var taken: Set<TabID> = []
        for index in windows.indices {
            let tab =
                windows[index].remembered[active].flatMap { open.contains($0) && !taken.contains($0) ? $0 : nil }
                ?? take(from: target, taken: taken, window: index, change: &change, newTab: newTab)
            taken.insert(tab)
            windows[index].remembered[active] = tab
        }
        return change
    }

    /// Drops every window's memory of `workspace`, once it is deleted.
    public mutating func forget(workspace: UUID) {
        for index in windows.indices { windows[index].remembered[workspace] = nil }
    }

    /// D4: shows `tab` in `window` unless another window shows it.
    public mutating func select(_ tab: TabID, in window: WindowID, of tabs: WorkspaceTabs) -> SelectOutcome {
        guard tabs.workspace == active, tabs.order.contains(tab), let index = index(of: window) else {
            return .unknown
        }
        if let other = self.window(showing: tab), other != window { return .shownIn(other) }
        windows[index].remembered[active] = tab
        return .selected
    }

    /// A tab just opened for `window` in `workspace` (new tab, link, popup, a tab received from another workspace).
    public mutating func opened(_ tab: TabID, in workspace: UUID, window: WindowID) {
        guard let index = index(of: window) else { return }
        windows[index].remembered[workspace] = tab
    }

    /// D3: before `closing` closes in `tabs.workspace`, each window showing one of them moves to the next tab in
    /// `order` that stays and no window shows, else the nearest such one before it, else a new blank it does not
    /// own. For a workspace that is not active only memory is pruned.
    public mutating func closing(
        _ closing: Set<TabID>, in tabs: WorkspaceTabs, newTab: () -> TabID = { TabID() }
    ) -> SelectionChange {
        var change = SelectionChange()
        for index in windows.indices {
            windows[index].ownedBlanks.subtract(closing)
            guard let tab = windows[index].remembered[tabs.workspace], closing.contains(tab) else { continue }
            guard tabs.workspace == active else {
                windows[index].remembered[tabs.workspace] = nil
                continue
            }
            let shown = shownTabs
            let free = { (id: TabID) in !closing.contains(id) && !shown.contains(id) }
            let position = tabs.order.firstIndex(of: tab) ?? tabs.order.endIndex
            let next =
                tabs.order[position...].first(where: free) ?? tabs.order[..<position].last(where: free)
                ?? {
                    let blank = newTab()
                    change.create.append(blank)
                    return blank
                }()
            windows[index].remembered[active] = next
        }
        return change
    }

    private func index(of window: WindowID) -> Int? {
        windows.firstIndex { $0.id == window }
    }

    /// D3's rule past a window's own tab: the first untaken tab in `order`, else a new blank `window` owns.
    private mutating func take(
        from tabs: WorkspaceTabs, taken: Set<TabID>, window: Int, change: inout SelectionChange,
        newTab: () -> TabID
    ) -> TabID {
        if let tab = tabs.order.first(where: { !taken.contains($0) }) { return tab }
        let blank = newTab()
        change.create.append(blank)
        windows[window].ownedBlanks.insert(blank)
        return blank
    }
}
