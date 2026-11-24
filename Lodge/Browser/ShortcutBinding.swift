import LodgeKit
import SwiftUI

extension View {
    /// Attaches the catalog key only while `enabled` (D7) and disables the item otherwise. A key that yields to the
    /// page is never attached (D10).
    func shortcut(_ id: ShortcutID, enabled: Bool = true) -> some View {
        let shortcut = ShortcutCatalog[id]
        return keyboardShortcut(enabled && !shortcut.yieldsToPage ? KeyboardShortcut(shortcut.combo) : nil)
            .disabled(!enabled)
    }
}
