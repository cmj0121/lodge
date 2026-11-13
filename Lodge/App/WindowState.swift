import Foundation
import LodgeKit
import Observation

/// One browser window's own state: the workspace it shows and its floating surfaces (find, downloads popover,
/// shortcut overlay, location prompt), which stay with the window when it switches workspace.
@MainActor
@Observable
final class WindowState {
    var activeWorkspace: UUID
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

    init(activeWorkspace: UUID = Workspace.defaultID) {
        self.activeWorkspace = activeWorkspace
    }

    /// Before a switch: hides find (clearing its miss), the location prompt and the shortcut overlay, which belong to
    /// the workspace's page; the Downloads popover stays, the list being shared.
    func closeTransientSurfaces() {
        if isFindVisible { isFindVisible = false }
        if findMissed { findMissed = false }
        if locationPrompt != nil { locationPrompt = nil }
        if isShortcutHelpVisible { isShortcutHelpVisible = false }
    }
}
