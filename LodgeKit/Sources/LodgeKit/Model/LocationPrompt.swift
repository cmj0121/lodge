import Foundation

/// What the floating location prompt is open for, and so where Enter sends the address.
public enum LocationPrompt: Equatable, Sendable {
    /// ⌘T or the sidebar's +: Enter opens a new selected tab on the address; Esc leaves no tab behind.
    case newTab
    /// ⌘L: Enter loads the address in that tab.
    case current(TabID)

    /// The text the prompt opens with: empty for a new tab; for the current one the words of a results page of one of
    /// `engines` (`SearchResultsPage`), else the page's address.
    public func initialText(for url: URL?, engines: [SearchEngine] = []) -> String {
        switch self {
        case .newTab: ""
        case .current:
            url.flatMap { SearchResultsPage.match($0, engines: engines)?.words } ?? url?.absoluteString ?? ""
        }
    }
}
