import LodgeKit
import SwiftUI

extension KeyboardShortcut {
    init(_ combo: KeyCombo) {
        var modifiers: EventModifiers = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        self.init(KeyEquivalent(combo.key), modifiers: modifiers)
    }
}

extension View {
    /// Attaches the catalog key only while `enabled` (D7) and disables the item otherwise. A key that yields to the
    /// page is never attached (D10).
    func shortcut(_ id: ShortcutID, enabled: Bool = true) -> some View {
        let shortcut = ShortcutCatalog[id]
        return keyboardShortcut(enabled && !shortcut.yieldsToPage ? KeyboardShortcut(shortcut.combo) : nil)
            .disabled(!enabled)
    }
}
