import Foundation

/// The popups a tab opened, and the ones they opened in turn.
public enum PopupTree {
    /// Every tab `tab` opened, directly or through its popups, given each popup's opener; parents come before their
    /// popups, `tab` itself is left out, and a loop among the openers ends the walk instead of repeating it.
    public static func descendants(of tab: TabID, openers: [TabID: TabID]) -> [TabID] {
        var popups: [TabID: [TabID]] = [:]
        for (popup, opener) in openers { popups[opener, default: []].append(popup) }
        var found: [TabID] = []
        var seen: Set<TabID> = [tab]
        var queue = [tab]
        while !queue.isEmpty {
            for popup in popups[queue.removeFirst()] ?? [] where seen.insert(popup).inserted {
                found.append(popup)
                queue.append(popup)
            }
        }
        return found
    }
}
