import AppKit
import LodgeKit
import WebKit

/// Each workspace's look, System, Light or Dark, and the one place that applies it. A browser window takes the look
/// of the workspace it shows, and Anonymous's windows are always dark. A page takes the look of its own workspace in
/// whatever window shows it, so `prefers-color-scheme`, form controls and scrollbars follow that workspace's choice;
/// on System they follow the Mac's.
@MainActor
enum WindowAppearance {
    private static var appearances: [UUID: WorkspaceAppearance] = [:]
    /// Each browser window this has given a look, with the workspace it shows.
    private static let windows = NSMapTable<NSWindow, NSUUID>.weakToStrongObjects()
    /// Each tab's web view, with the workspace it belongs to.
    private static let webViews = NSMapTable<WKWebView, NSUUID>.weakToStrongObjects()
    private static var systemObserver: NSKeyValueObservation?

    /// Records the workspace's look and gives it at once to every window and page of that workspace, with no
    /// reload.
    static func set(_ appearance: WorkspaceAppearance, for workspace: UUID) {
        appearances[workspace] = appearance
        for window in members(of: workspace, in: windows) { window.appearance = chrome(for: workspace) }
        for webView in members(of: workspace, in: webViews) { webView.appearance = page(for: workspace) }
    }

    /// Drops a workspace that has left the list; its windows take another workspace's look on the switch away.
    static func forget(_ workspace: UUID) {
        appearances[workspace] = nil
    }

    /// The look recorded for the workspace; nil once it is forgotten or before it is set.
    static func recorded(_ workspace: UUID) -> WorkspaceAppearance? {
        appearances[workspace]
    }

    /// Sets a browser window's look for the workspace it shows, on register and on every switch.
    static func apply(_ workspace: Workspace, to window: NSWindow) {
        appearances[workspace.id] = workspace.appearance
        windows.setObject(workspace.id as NSUUID, forKey: window)
        window.appearance = chrome(for: workspace.id)
    }

    /// Gives a tab's new web view its workspace's look from now on, in any window.
    static func track(_ webView: WKWebView, workspace: UUID) {
        webViews.setObject(workspace as NSUUID, forKey: webView)
        webView.appearance = page(for: workspace)
        guard systemObserver == nil else { return }
        systemObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                for case let webView as WKWebView in webViews.keyEnumerator().allObjects {
                    guard let id = webViews.object(forKey: webView).map({ $0 as UUID }),
                        appearances[id, default: .system] == .system
                    else { continue }
                    webView.appearance = NSApp.effectiveAppearance
                }
            }
        }
    }

    /// Nil for System, so the window inherits the Mac's look.
    private static func chrome(for workspace: UUID) -> NSAppearance? {
        if workspace == Workspace.anonymousID { return NSAppearance(named: .darkAqua) }
        return switch appearances[workspace, default: .system] {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Never nil: a page in a window of another look still follows its own workspace, or the Mac on System.
    private static func page(for workspace: UUID) -> NSAppearance? {
        switch appearances[workspace, default: .system] {
        case .system: NSApp.effectiveAppearance
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private static func members<View: AnyObject>(of workspace: UUID, in table: NSMapTable<View, NSUUID>) -> [View] {
        table.keyEnumerator().allObjects.compactMap { $0 as? View }
            .filter { table.object(forKey: $0).map { $0 as UUID } == workspace }
    }
}
