import AppKit
import LodgeKit
import SwiftUI

/// Menu bar items and their keyboard shortcuts.
struct BrowserCommands: Commands {
    let model: BrowserModel
    let history: HistoryModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.isBrowserWindow) private var isBrowserWindow
    @AppStorage(SidebarMode.defaultsKey) private var sidebarMode: SidebarMode = .expanded

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(ShortcutCatalog[.newTab].title, action: model.newTab)
                .shortcut(.newTab)
            Button(ShortcutCatalog[.openLocation].title, action: model.focusAddressBar)
                .shortcut(.openLocation)
        }
        CommandGroup(replacing: .saveItem) {
            Button(isBrowserWindow == true ? ShortcutCatalog[.closeTab].title : "Close Window") {
                if isBrowserWindow == true { model.closeSelectedTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
                .shortcut(.closeTab)
            if isBrowserWindow == true {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            }
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(ShortcutCatalog[.find].title, action: model.showFind)
                .shortcut(.find)
            Button("Find Next", action: model.findNext)
            Button("Find Previous", action: model.findPrevious)
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                model.closeDownloadsForModeChange()
                withAnimation(.snappy(duration: 0.25)) { sidebarMode = sidebarMode.toggled }
            }
        }
        CommandGroup(before: .toolbar) {
            Button(ShortcutCatalog[.reload].title, action: model.reload)
                .shortcut(.reload)
            Button("Stop", action: model.stopLoading)
            Divider()
            Button(model.isDownloadsVisible ? "Hide Downloads" : "Show Downloads") { model.isDownloadsVisible.toggle() }
                .shortcut(.toggleDownloads)
            Divider()
            Button(ShortcutCatalog[.zoomIn].title, action: model.zoomIn)
                .shortcut(.zoomIn, enabled: model.canZoomIn)
            Button(ShortcutCatalog[.zoomOut].title, action: model.zoomOut)
                .shortcut(.zoomOut, enabled: model.canZoomOut)
            Button(ShortcutCatalog[.actualSize].title, action: model.resetZoom)
                .shortcut(.actualSize, enabled: model.canResetZoom)
            Divider()
        }
        CommandMenu("History") {
            Button("Back", action: model.goBack)
            Button("Forward", action: model.goForward)
            Divider()
            Button("Show All History") { openWindow(id: "history") }
            Button("Clear All History…") { HistoryPrompts.clearAll(model: history) }
                .disabled(!history.canClearAll)
        }
        CommandMenu("Bookmarks") {
            Button(ShortcutCatalog[.bookmarkTab].title, action: model.bookmarkSelectedTab)
                .shortcut(.bookmarkTab, enabled: model.tabs.selectedID.map(model.canAddLink) == true)
            Button(model.isSelectedTabPinned ? "Unpin Tab" : "Pin This Tab", action: model.togglePinSelectedTab)
                .disabled(model.tabs.selectedID.map(model.canAddLink) != true)
            Button("New Folder…") { BookmarkPrompts.newFolder(in: nil, model: model) }
            Divider()
            Button("Import Bookmarks…") { BookmarkTransfer.importBookmarks(into: model) }
                .disabled(model.isImportingBookmarks)
            Button("Export Bookmarks…") { BookmarkTransfer.exportBookmarks(from: model) }
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab", action: model.selectNextTab)
            Button("Show Previous Tab", action: model.selectPreviousTab)
            Divider()
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { model.isShortcutHelpVisible = true }
        }
    }
}
