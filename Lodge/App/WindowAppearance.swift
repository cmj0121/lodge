import AppKit
import LodgeKit
import WebKit

/// Anonymous looks the part: while it is the active workspace every browser window is dark, whatever the system's
/// look. Pages are not: each web view stays pinned to the system appearance, so `prefers-color-scheme`, form controls
/// and scrollbars match what the user chose for their Mac.
@MainActor
enum WindowAppearance {
    /// Windows this has darkened, so leaving Anonymous gives back only those and never a look someone else set.
    private static let darkened = NSHashTable<NSWindow>.weakObjects()
    private static let pinned = NSHashTable<WKWebView>.weakObjects()
    private static var systemObserver: NSKeyValueObservation?

    static func appearance(for kind: WorkspaceKind) -> NSAppearance? {
        kind == .anonymous ? NSAppearance(named: .darkAqua) : nil
    }

    /// Sets a browser window's look for the workspace it shows.
    static func apply(_ kind: WorkspaceKind, to window: NSWindow) {
        if let dark = appearance(for: kind) {
            guard !darkened.contains(window) else { return }
            darkened.add(window)
            window.appearance = dark
        } else if darkened.contains(window) {
            darkened.remove(window)
            window.appearance = nil
        }
    }

    /// Keeps the web view in the system's appearance from now on, even inside a dark window.
    static func pin(_ webView: WKWebView) {
        guard !pinned.contains(webView) else { return }
        pinned.add(webView)
        webView.appearance = NSApp.effectiveAppearance
        guard systemObserver == nil else { return }
        systemObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                for view in pinned.allObjects { view.appearance = NSApp.effectiveAppearance }
            }
        }
    }
}
