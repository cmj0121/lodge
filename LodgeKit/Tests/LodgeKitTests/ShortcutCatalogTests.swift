import Testing

@testable import LodgeKit

@Suite struct ShortcutCatalogTests {
    @Test func catalogHoldsExactlyTheShortcutSetInOrder() {
        let expected: [(ShortcutID, String, ShortcutMenu, String)] = [
            (.newTab, "New Tab", .file, "⌘T"),
            (.closeTab, "Close Tab", .file, "⌘W"),
            (.openLocation, "Open Location…", .file, "⌘L"),
            (.reload, "Reload Page", .view, "⌘R"),
            (.find, "Find…", .edit, "⌘F"),
            (.bookmarkTab, "Bookmark This Tab", .bookmarks, "⌘D"),
            (.toggleDownloads, "Show Downloads", .view, "⌘J"),
            (.zoomIn, "Zoom In", .view, "⌘="),
            (.zoomOut, "Zoom Out", .view, "⌘-"),
            (.actualSize, "Actual Size", .view, "⌘0"),
            (.shortcutHelp, "Keyboard Shortcuts", .help, "⌘/"),
        ]
        let all = ShortcutCatalog.all
        #expect(all.count == expected.count)
        for (shortcut, (id, title, menu, display)) in zip(all, expected) {
            #expect(shortcut.id == id)
            #expect(shortcut.title == title)
            #expect(shortcut.menu == menu)
            #expect(shortcut.combo.display == display)
        }
        #expect(Set(all.map(\.id)) == Set(ShortcutID.allCases))
    }

    @Test func onlyZoomInHasThePlusAlias() {
        for shortcut in ShortcutCatalog.all where shortcut.id != .zoomIn {
            #expect(shortcut.aliases.isEmpty)
        }
        #expect(ShortcutCatalog[.zoomIn].aliases == [KeyCombo("+")])
        #expect(ShortcutCatalog[.zoomIn].aliases.map(\.display) == ["⌘+"])
    }

    @Test func noTwoCombosCollideIncludingAliases() {
        let combos = ShortcutCatalog.all.flatMap { [$0.combo] + $0.aliases }
        #expect(Set(combos).count == combos.count)
    }

    @Test func everyPrimaryComboIsCommandPlusOneKey() {
        for shortcut in ShortcutCatalog.all {
            #expect(shortcut.combo.modifiers == .command)
        }
    }

    @Test func subscriptFindsEveryID() {
        for id in ShortcutID.allCases {
            #expect(ShortcutCatalog[id].id == id)
        }
    }

    @Test func displayOrdersModifierGlyphsAndUppercasesLetters() {
        #expect(KeyCombo("t").display == "⌘T")
        #expect(KeyCombo("0").display == "⌘0")
        #expect(KeyCombo("w", [.command, .shift]).display == "⇧⌘W")
        #expect(KeyCombo("s", [.command, .control, .option, .shift]).display == "⌃⌥⇧⌘S")
    }

    @Test func groupedFollowsMenuOrderAndDropsEmptyGroups() {
        let grouped = ShortcutCatalog.grouped
        #expect(grouped.map(\.menu) == [.file, .edit, .view, .bookmarks, .help])
        #expect(grouped[0].shortcuts.map(\.id) == [.newTab, .closeTab, .openLocation])
        #expect(grouped[1].shortcuts.map(\.id) == [.find])
        #expect(grouped[2].shortcuts.map(\.id) == [.reload, .toggleDownloads, .zoomIn, .zoomOut, .actualSize])
        #expect(grouped[3].shortcuts.map(\.id) == [.bookmarkTab])
        #expect(grouped[4].shortcuts.map(\.id) == [.shortcutHelp])
        #expect(grouped.allSatisfy { !$0.shortcuts.isEmpty })
    }

    @Test func onlyShortcutHelpYieldsToThePageAndCarriesANote() {
        for shortcut in ShortcutCatalog.all where shortcut.id != .shortcutHelp {
            #expect(!shortcut.yieldsToPage)
            #expect(shortcut.note == nil)
        }
        #expect(ShortcutCatalog[.shortcutHelp].yieldsToPage)
        #expect(ShortcutCatalog[.shortcutHelp].note == "outside the page")
    }

    @Test func tooltipAppendsTheKey() {
        #expect(ShortcutCatalog.tooltip("Open a new tab", for: .newTab) == "Open a new tab (⌘T)")
        #expect(ShortcutCatalog.tooltip("Zoom in", for: .zoomIn) == "Zoom in (⌘=)")
    }
}
