import Foundation

/// How hard the system asks for memory back: a warning rests every tab that can go; critical also drops what
/// rebuilds without the network.
public enum MemoryPressureLevel: Sendable {
    case warning, critical
}

extension TabRest {
    /// For memory pressure across workspaces: each workspace's `oldestFirst` of its `live` tabs, merged by when each
    /// was last on screen, oldest first, tabs never stamped last; tabs in `shown` are left out. Equal stamps keep the
    /// workspaces' order, then each workspace's own.
    public static func oldestFirst(_ workspaces: [(rest: TabRest, live: [TabID])], shown: Set<TabID>) -> [TabID] {
        let ranked = workspaces.enumerated().flatMap { workspace, entry in
            entry.rest.oldestFirst(entry.live).enumerated().compactMap { position, tab in
                shown.contains(tab)
                    ? nil : (seen: entry.rest.lastSeen(tab), workspace: workspace, position: position, tab: tab)
            }
        }
        return ranked.sorted { a, b in
            switch (a.seen, b.seen) {
            case (let x?, let y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return (a.workspace, a.position) < (b.workspace, b.position)
            }
        }.map(\.tab)
    }
}
