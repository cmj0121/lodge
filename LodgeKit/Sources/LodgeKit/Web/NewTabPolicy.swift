import Foundation

/// Which link URLs may open as a new live tab (Cmd-click). The new tab loads its URL as a
/// browser-initiated navigation, which skips WebKit's blocks on top-level `data:` and `file:`
/// navigations, so only http/https and `about:blank` qualify; any other link stays with WebKit.
public enum NewTabPolicy {
    public static func allows(_ url: URL) -> Bool {
        Origin.isWeb(url) || url.absoluteString.lowercased() == "about:blank"
    }

    /// Which history URLs may open as a new tab: only web pages, which is all the recorder keeps, so a row
    /// written into the file by anything else cannot load `file:` or `javascript:` as a browser navigation.
    public static func allowsFromHistory(_ url: URL) -> Bool {
        Origin.isWeb(url)
    }
}
