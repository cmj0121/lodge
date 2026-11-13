import AppKit
import LodgeKit
import SwiftUI

/// Menu bar items and their keyboard shortcuts.
struct BrowserCommands: Commands {
    let coordinator: WorkspaceCoordinator
    let history: HistoryModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.isBrowserWindow) private var isBrowserWindow
    @AppStorage(SidebarMode.defaultsKey) private var sidebarMode: SidebarMode = .expanded

    /// The last active browser window's pane, which every item acts on; nil with no browser window.
    private var pane: BrowserPane? { coordinator.commandPane }

    /// The shown tab has a page to save as a link.
    private var canAddLink: Bool {
        guard let pane, let id = pane.selectedID else { return false }
        return pane.model.canAddLink(from: id)
    }

    /// The window the bookmark file panels go on.
    private var browserWindow: NSWindow? { coordinator.lastActiveBrowserWindow?.nsWindow }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(ShortcutCatalog[.newTab].title) { pane?.newTab() }
                .shortcut(.newTab)
            Button(ShortcutCatalog[.openLocation].title) { pane?.focusAddressBar() }
                .shortcut(.openLocation)
        }
        CommandGroup(replacing: .saveItem) {
            Button(isBrowserWindow == true ? ShortcutCatalog[.closeTab].title : "Close Window") {
                if isBrowserWindow == true { pane?.closeSelectedTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
                .shortcut(.closeTab)
            if isBrowserWindow == true {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            }
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(ShortcutCatalog[.find].title) { pane?.showFind() }
                .shortcut(.find)
            Button("Find Next") { pane?.findNext() }
            Button("Find Previous") { pane?.findPrevious() }
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                pane?.closeDownloadsForModeChange()
                withAnimation(.snappy(duration: 0.25)) { sidebarMode = sidebarMode.toggled }
            }
        }
        CommandGroup(before: .toolbar) {
            Button(ShortcutCatalog[.reload].title) { pane?.reload() }
                .shortcut(.reload)
            Button("Stop") { pane?.stopLoading() }
            Divider()
            Button(pane?.window.isDownloadsVisible == true ? "Hide Downloads" : "Show Downloads") { pane?.toggleDownloads() }
                .shortcut(.toggleDownloads)
            Divider()
            Button(ShortcutCatalog[.zoomIn].title) { pane?.zoomIn() }
                .shortcut(.zoomIn, enabled: pane?.canZoomIn == true)
            Button(ShortcutCatalog[.zoomOut].title) { pane?.zoomOut() }
                .shortcut(.zoomOut, enabled: pane?.canZoomOut == true)
            Button(ShortcutCatalog[.actualSize].title) { pane?.resetZoom() }
                .shortcut(.actualSize, enabled: pane?.canResetZoom == true)
            Divider()
        }
        CommandMenu("History") {
            Button("Back") { pane?.goBack() }
            Button("Forward") { pane?.goForward() }
            Divider()
            Button("Show All History") { openWindow(id: "history") }
            Button("Clear All History…") { HistoryPrompts.clearAll(model: history) }
                .disabled(!history.canClearAll)
        }
        CommandMenu("Bookmarks") {
            Button(ShortcutCatalog[.bookmarkTab].title) { pane?.bookmarkSelectedTab() }
                .shortcut(.bookmarkTab, enabled: canAddLink)
            Button(pane?.isSelectedTabPinned == true ? "Unpin Tab" : "Pin This Tab") { pane?.togglePinSelectedTab() }
                .disabled(!canAddLink)
            Button("New Folder…") { if let model = pane?.model { BookmarkPrompts.newFolder(in: nil, model: model) } }
            Divider()
            Button("Import Bookmarks…") {
                if let model = pane?.model { BookmarkTransfer.importBookmarks(into: model, on: browserWindow) }
            }
            .disabled(pane?.model.isImportingBookmarks != false)
            Button("Export Bookmarks…") {
                if let model = pane?.model { BookmarkTransfer.exportBookmarks(from: model, on: browserWindow) }
            }
        }
        CommandMenu("Workspaces") {
            Button("New Workspace…") { pane?.showWorkspaceEditor(.create) }
                .disabled(isBrowserWindow != true)
            Divider()
            let activeID = coordinator.activeWorkspace.id
            ForEach(1...ShortcutID.workspaceSlots.count, id: \.self) { slot in
                if let workspace = coordinator.workspaces.workspace(forSlot: slot) {
                    Toggle(
                        workspace.name,
                        isOn: Binding(get: { workspace.id == activeID }, set: { _ in
                            // As every catalog key does: what floats over the page closes first, also when the
                            // workspace is already the one shown.
                            pane?.closeFloatingSurfaces()
                            coordinator.switchTo(workspace.id)
                        })
                    )
                    .shortcut(.workspace(slot: slot)!, enabled: isBrowserWindow == true)
                }
            }
            let anonymous = coordinator.workspaces.anonymous
            Toggle(
                anonymous.name,
                isOn: Binding(get: { anonymous.id == activeID }, set: { _ in
                    pane?.closeFloatingSurfaces()
                    coordinator.switchTo(anonymous.id)
                })
            )
            .disabled(isBrowserWindow != true)
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { pane?.selectNextTab() }
            Button("Show Previous Tab") { pane?.selectPreviousTab() }
            Divider()
        }
        CommandGroup(after: .help) {
            Button(ShortcutCatalog[.shortcutHelp].title) { pane?.showShortcutHelp() }
                .shortcut(.shortcutHelp)
        }
    }
}
