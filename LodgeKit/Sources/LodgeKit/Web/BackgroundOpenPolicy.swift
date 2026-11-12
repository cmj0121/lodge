import Foundation

/// Which link targets Cmd-click may hand to a new tab. The new tab loads its URL as a
/// browser-initiated navigation, which skips WebKit's blocks on top-level `data:` and `file:`
/// navigations, so only web URLs and `about:blank` qualify; any other link stays with WebKit.
public enum BackgroundOpenPolicy {
    public static func allows(_ url: URL) -> Bool {
        Origin.isWeb(url) || url.absoluteString.lowercased() == "about:blank"
    }
}
