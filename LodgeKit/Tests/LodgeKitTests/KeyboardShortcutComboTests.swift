import SwiftUI
import Testing

@testable import LodgeKit

@Suite struct KeyboardShortcutComboTests {
    @Test func slotKeysKeepTheirKeyAndModifiers() {
        #expect(KeyboardShortcut(KeyCombo("3", .control)) == KeyboardShortcut("3", modifiers: .control))
        #expect(KeyboardShortcut(KeyCombo("3")) == KeyboardShortcut("3", modifiers: .command))
    }

    @Test func everyModifierCarriesOver() {
        let combo = KeyCombo("k", [.command, .shift, .option, .control])
        #expect(KeyboardShortcut(combo) == KeyboardShortcut("k", modifiers: [.command, .shift, .option, .control]))
    }

    @Test func slotKeysWinOverThePage() {
        for id in ShortcutID.workspaceSlots + ShortcutID.pinSlots {
            #expect(!ShortcutCatalog[id].yieldsToPage)
        }
    }
}
