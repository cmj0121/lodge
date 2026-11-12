import Foundation

/// Which link URLs may open as a new live tab (Cmd-click). The new tab loads its URL as a
/// browser-initiated navigation, which skips WebKit's blocks on top-level `data:` and `file:`
/// navigations, so only http/https and `about:blank` qualify; any other link stays with WebKit.
public enum NewTabPolicy {
    public static func allows(_ url: URL) -> Bool {
        Origin.isWeb(url) || url.absoluteString.lowercased() == "about:blank"
    }
}
