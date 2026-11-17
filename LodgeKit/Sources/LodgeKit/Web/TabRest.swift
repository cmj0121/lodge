import Foundation

/// Settings › General › "Rest tabs after"; stored in UserDefaults under `restTabsAfter` as minutes (0 = never).
public enum RestAfter: Int, CaseIterable, Sendable {
    case five = 5, fifteen = 15, thirty = 30, sixty = 60, never = 0
    public static let standard: RestAfter = .five
    public static let defaultsKey = "restTabsAfter"
    public var interval: Duration? { self == .never ? nil : .seconds(rawValue * 60) }

    /// The stored choice; a missing or unknown value is `standard`.
    public static func load(from defaults: UserDefaults) -> RestAfter {
        guard let minutes = defaults.object(forKey: defaultsKey) as? Int else { return .standard }
        return RestAfter(rawValue: minutes) ?? .standard
    }
}

/// When each tab of one workspace was last on screen; times are passed in, never read, so tests need no clock.
public struct TabRest: Equatable, Sendable {
    private var shown: Set<TabID> = []
    private var seen: [TabID: ContinuousClock.Instant] = [:]

    public init() {}

    /// Every selection change: tabs that just left `shown` are stamped `now`; tabs in `shown` are on screen. A tab of
    /// `live` (with a view) never stamped is stamped `now`, so it rests in time rather than never.
    public mutating func update(shown: Set<TabID>, live: [TabID] = [], now: ContinuousClock.Instant) {
        for tab in self.shown.union(shown) { seen[tab] = now }
        for tab in live where seen[tab] == nil { seen[tab] = now }
        self.shown = shown
    }

    public mutating func forget(_ tab: TabID) {
        shown.remove(tab)
        seen[tab] = nil
    }

    /// Tabs with a view, not shown, unseen for at least `after`, oldest first. A tab never stamped is not due; `update`
    /// stamps it the first time it is seen with a view, so it is never due at once.
    public func due(_ live: [TabID], after: Duration, now: ContinuousClock.Instant) -> [TabID] {
        oldestFirst(live).filter { seen[$0].map { now - $0 >= after } == true }
    }

    /// When the next of `live` falls due, for scheduling one timer; nil when none can.
    public func nextDue(_ live: [TabID], after: Duration) -> ContinuousClock.Instant? {
        live.lazy.filter { !shown.contains($0) }.compactMap { seen[$0] }.min().map { $0 + after }
    }

    /// For memory pressure: `live` minus shown, least recently seen first; a tab never stamped comes first.
    public func oldestFirst(_ live: [TabID]) -> [TabID] {
        let unshown = live.filter { !shown.contains($0) }
        return unshown.enumerated().sorted { a, b in
            switch (seen[a.element], seen[b.element]) {
            case (nil, nil): a.offset < b.offset
            case (nil, _): true
            case (_, nil): false
            case (let x?, let y?): x == y ? a.offset < b.offset : x < y
            }
        }.map(\.element)
    }

    public func lastSeen(_ tab: TabID) -> ContinuousClock.Instant? { seen[tab] }
}

extension BrowserTab {
    /// The tab has a web page but no web view (rested, released or restored): selecting it rebuilds the page. A Lodge
    /// page never has a view, so it never rests.
    public var isResting: Bool { url != nil && !isLive && lodgePage == nil }
}
