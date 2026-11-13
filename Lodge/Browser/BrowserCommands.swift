import AppKit
import LodgeKit
import SwiftUI

/// Menu bar items and their keyboard shortcuts.
struct BrowserCommands: Commands {
    let model: BrowserModel
    let history: HistoryModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarMode.defaultsKey) private var sidebarMode: SidebarMode = .expanded

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab", action: model.newTab)
                .keyboardShortcut("t")
            Button("Open Location…", action: model.focusAddressBar)
                .keyboardShortcut("l")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab", action: model.closeSelectedTab)
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…", action: model.showFind)
                .keyboardShortcut("f")
            Button("Find Next", action: model.findNext)
                .keyboardShortcut("g")
            Button("Find Previous", action: model.findPrevious)
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { withAnimation(.snappy(duration: 0.25)) { sidebarMode = sidebarMode.toggled } }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page", action: model.reload)
                .keyboardShortcut("r")
            Button("Stop", action: model.stopLoading)
                .keyboardShortcut(".")
            Divider()
        }
        CommandMenu("History") {
            Button("Back", action: model.goBack)
                .keyboardShortcut("[")
            Button("Forward", action: model.goForward)
                .keyboardShortcut("]")
            Divider()
            Button("Show All History") { openWindow(id: "history") }
                .keyboardShortcut("y")
            Button("Clear All History…") { HistoryPrompts.clearAll(model: history) }
                .disabled(!history.canClearAll)
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Tab", action: model.bookmarkSelectedTab)
                .keyboardShortcut("d")
                .disabled(model.tabs.selectedID.map(model.canAddLink) != true)
            Button("New Folder…") { BookmarkPrompts.newFolder(in: nil, model: model) }
            Divider()
            Button("Import Bookmarks…") { BookmarkTransfer.importBookmarks(into: model) }
                .disabled(model.isImportingBookmarks)
            Button("Export Bookmarks…") { BookmarkTransfer.exportBookmarks(from: model) }
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab", action: model.selectNextTab)
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab", action: model.selectPreviousTab)
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
        }
    }
}
