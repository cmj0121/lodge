import SwiftUI

extension KeyboardShortcut {
    /// The SwiftUI key for a catalog combo, shared by the macOS and iOS menus.
    public init(_ combo: KeyCombo) {
        var modifiers: EventModifiers = []
        if combo.modifiers.contains(.command) { modifiers.insert(.command) }
        if combo.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if combo.modifiers.contains(.option) { modifiers.insert(.option) }
        if combo.modifiers.contains(.control) { modifiers.insert(.control) }
        self.init(KeyEquivalent(combo.key), modifiers: modifiers)
    }
}
