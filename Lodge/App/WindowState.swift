import AppKit
import LodgeKit
import Observation

/// One browser window's own state: its floating surfaces (find, downloads popover, shortcut overlay, location
/// prompt), which stay with the window when the workspace switches. The tab it shows is the coordinator's
/// (`WindowSelections`), every window being on the active workspace.
@MainActor
@Observable
final class WindowState {
    let id: WindowID
    /// The window on screen, once `WindowRegistrar` has seen it.
    @ObservationIgnored weak var nsWindow: NSWindow?
    var findText = ""
    var isFindVisible = false
    var findMissed = false
    /// Bumped to ask the window to focus the find field.
    var findFocusRequest = 0
    /// The text the last search ran for, so the typing debounce does not search it again.
    @ObservationIgnored var lastSearchedText = ""
    /// The sidebar's Downloads popover is open.
    var isDownloadsVisible = false
    /// The keyboard shortcut help overlay is open.
    var isShortcutHelpVisible = false
    /// The floating location prompt, open for a new tab or for the tab it loads in; nil when closed.
    var locationPrompt: LocationPrompt?
    /// The workspace sheet, open to create a workspace or to rename one or change its icon; nil when closed.
    var workspaceEditor: WorkspaceEditor?

    init(id: WindowID = WindowID()) {
        self.id = id
    }

    /// Another tab is shown: find hides and its miss clears.
    func dismissFind() {
        if isFindVisible { isFindVisible = false }
        if findMissed { findMissed = false }
    }

    /// Before a switch: hides find (clearing its miss), the location prompt, the shortcut overlay and the workspace
    /// sheet, which belong to the workspace's page; the Downloads popover stays, the list being shared.
    func closeTransientSurfaces() {
        if isFindVisible { isFindVisible = false }
        if findMissed { findMissed = false }
        if locationPrompt != nil { locationPrompt = nil }
        if isShortcutHelpVisible { isShortcutHelpVisible = false }
        if workspaceEditor != nil { workspaceEditor = nil }
    }
}
