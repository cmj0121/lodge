import Testing

@testable import LodgeKit

@Suite struct ShortcutCatalogTests {
    @Test func catalogHoldsExactlyTheShortcutSetInOrder() {
        let expected: [(ShortcutID, String, ShortcutMenu, String)] = [
            (.newTab, "New Tab", .file, "⌘T"),
            (.newWindow, "New Window", .file, "⌘N"),
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
        ] + (1...9).map { n in (ShortcutID.workspaceSlots[n - 1], "Workspace \(n)", .workspaces, "⌘\(n)") }
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
        #expect(grouped.map(\.menu) == [.file, .edit, .view, .bookmarks, .workspaces, .help])
        #expect(grouped[0].shortcuts.map(\.id) == [.newTab, .newWindow, .closeTab, .openLocation])
        #expect(grouped[1].shortcuts.map(\.id) == [.find])
        #expect(grouped[2].shortcuts.map(\.id) == [.reload, .toggleDownloads, .zoomIn, .zoomOut, .actualSize])
        #expect(grouped[3].shortcuts.map(\.id) == [.bookmarkTab])
        #expect(grouped[4].shortcuts.map(\.id) == [.workspace1])
        #expect(grouped[5].shortcuts.map(\.id) == [.shortcutHelp])
        #expect(grouped.allSatisfy { !$0.shortcuts.isEmpty })
    }

    @Test func onlyShortcutHelpYieldsToThePage() {
        for shortcut in ShortcutCatalog.all where shortcut.id != .shortcutHelp {
            #expect(!shortcut.yieldsToPage)
        }
        #expect(ShortcutCatalog[.shortcutHelp].yieldsToPage)
    }

    @Test func onlyShortcutHelpAndWorkspace1CarryANote() {
        for shortcut in ShortcutCatalog.all where ![.shortcutHelp, .workspace1].contains(shortcut.id) {
            #expect(shortcut.note == nil)
        }
        #expect(ShortcutCatalog[.workspace1].note == "⌘2–⌘9 next")
        #expect(ShortcutCatalog[.shortcutHelp].note == "outside the page")
    }

    @Test func tooltipAppendsTheKey() {
        #expect(ShortcutCatalog.tooltip("Open a new tab", for: .newTab) == "Open a new tab (⌘T)")
        #expect(ShortcutCatalog.tooltip("Zoom in", for: .zoomIn) == "Zoom in (⌘=)")
    }

    @Test func workspaceSlotsRunOneToNineInOrder() {
        #expect(
            ShortcutID.workspaceSlots == [
                .workspace1, .workspace2, .workspace3, .workspace4, .workspace5, .workspace6, .workspace7,
                .workspace8, .workspace9,
            ])
        for (index, id) in ShortcutID.workspaceSlots.enumerated() {
            #expect(id.workspaceSlot == index + 1)
            #expect(ShortcutID.workspace(slot: index + 1) == id)
            #expect(ShortcutCatalog[id].combo == KeyCombo(Character("\(index + 1)")))
        }
    }

    @Test func slotMappingRejectsOutOfRangeAndNonWorkspaceIDs() {
        #expect(ShortcutID.workspace(slot: 0) == nil)
        #expect(ShortcutID.workspace(slot: 10) == nil)
        #expect(ShortcutID.workspace(slot: -1) == nil)
        for id in ShortcutID.allCases where !ShortcutID.workspaceSlots.contains(id) {
            #expect(id.workspaceSlot == nil)
        }
    }

    @Test func onlyWorkspace1IsListedAmongTheSlots() {
        let hidden = Set(ShortcutID.workspaceSlots.dropFirst())
        for shortcut in ShortcutCatalog.all {
            #expect(shortcut.isListed == !hidden.contains(shortcut.id))
        }
        let listed = ShortcutCatalog.grouped.flatMap(\.shortcuts).map(\.isListed)
        #expect(!listed.contains(false))
    }

    @Test func workspaceKeysCollideWithNeitherActualSizeNorAliases() {
        let others = ShortcutCatalog.all.filter { $0.menu != .workspaces }.flatMap { [$0.combo] + $0.aliases }
        for id in ShortcutID.workspaceSlots {
            #expect(!others.contains(ShortcutCatalog[id].combo))
        }
        #expect(!ShortcutID.workspaceSlots.map { ShortcutCatalog[$0].combo }.contains(KeyCombo("0")))
    }

    @Test func noWorkspaceKeyEverReachesAnonymous() throws {
        var list = WorkspaceList()
        for count in 0...ShortcutID.workspaceSlots.count {
            if count > 0 { try list.create(name: "Custom \(count)", symbol: "folder") }
            for id in ShortcutID.workspaceSlots {
                let slot = try #require(id.workspaceSlot)
                #expect(list.workspace(forSlot: slot)?.kind != .anonymous)
            }
            #expect(list.slot(of: Workspace.anonymousID) == nil)
            #expect(list.workspaces.last == .anonymous)
        }
    }
}
