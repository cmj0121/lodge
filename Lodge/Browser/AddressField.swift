import AppKit
import SwiftUI

/// The address bar's text field. Every Copy its field editor receives (⌘C, Edit › Copy, the field's own menu) puts
/// `address`'s URL on the pasteboard in place of text when it gives one for the field's text and selected range.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    /// The URL Copy gives for the field's text and selected range; nil copies the selected text.
    let address: (String, NSRange) -> URL?
    /// Return; editing ends afterwards unless the submit already moved the keys elsewhere.
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.cell = AddressFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = String(localized: "Search or enter address")
        field.setAccessibilityLabel(String(localized: "Address"))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if let editor = (field.cell as? AddressFieldCell)?.editor {
            editor.address = address
            editor.focusChanged = { [coordinator = context.coordinator] in coordinator.focusChanged($0) }
        }
        if let editor = field.currentEditor() {
            if editor.string != text { editor.string = text }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField

        init(_ parent: AddressField) { self.parent = parent }

        /// The field editor took or gave up the keys, typed into or not.
        func focusChanged(_ isFocused: Bool) {
            if parent.isEditing != isFocused { parent.isEditing = isFocused }
        }

        func controlTextDidEndEditing(_ notification: Notification) { focusChanged(false) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        /// Return submits, Esc gives up the edit; either way the field stops editing.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): break
            default: return false
            }
            if control.currentEditor() != nil { control.window?.makeFirstResponder(nil) }
            return true
        }
    }
}

/// Hands its field its own field editor, so that editor's Copy can be the address's.
private final class AddressFieldCell: NSTextFieldCell {
    lazy var editor: AddressFieldEditor = {
        let editor = AddressFieldEditor()
        editor.isFieldEditor = true
        editor.allowsUndo = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

private final class AddressFieldEditor: NSTextView {
    var address: (String, NSRange) -> URL? = { _, _ in nil }
    /// True when it becomes first responder (a click or tab into the field), false when it resigns.
    var focusChanged: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusChanged(false) }
        return resigned
    }

    override func copy(_ sender: Any?) {
        if let url = address(string, selectedRange()) {
            NSPasteboard.general.setURL(url)
        } else {
            super.copy(sender)
        }
    }
}
