import AppKit
import LodgeKit
import SwiftUI

/// The text field of the address bar and the location prompt. Every Copy its field editor receives (⌘C,
/// Edit › Copy, the field's own menu) puts `address`'s URL on the pasteboard in place of text when it gives one for
/// the field's text and selected range. Each edit feeds `suggestions`; while it lists rows, ↑ / ↓ move its
/// highlight, Return opens the highlighted row and Esc closes the list keeping the text.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder = String(localized: "Search or enter address")
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    /// The URL Copy gives for the field's text and selected range; nil copies the selected text.
    let address: (String, NSRange) -> URL?
    /// The list each edit updates; nil keeps none.
    var suggestions: SuggestionModel?
    /// How many of `suggestions`' rows show in a panel under the field, read by the host so a change redraws the
    /// field; 0 shows no panel (the location prompt lists the rows itself).
    var panelRows = 0
    var icon: (Suggestion) -> NSImage? = { _ in nil }
    /// A row picked by Return or a click; editing ends afterwards as for `submit`.
    var choose: (Suggestion) -> Void = { _ in }
    /// Each change makes the field first responder with its text selected, once it is in a window.
    var focusRequest = 0
    /// False keeps the keys in the field after Return, for a host that closes when the submit goes somewhere.
    var endsEditingOnSubmit = true
    /// Return with no row highlighted; editing ends afterwards unless the submit already moved the keys elsewhere.
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
        field.font = font
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = placeholder
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
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                if window.makeFirstResponder(field) { field.currentEditor()?.selectAll(nil) }
            }
        }
        if let suggestions, panelRows > 0, field.currentEditor() != nil {
            let coordinator = context.coordinator
            context.coordinator.panel.show(
                SuggestionList(model: suggestions, icon: icon) { [weak field] row in
                    if let field { coordinator.choose(row, in: field) }
                },
                rows: panelRows, under: field)
        } else {
            context.coordinator.panel.hide()
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.panel.hide() }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var focusRequest = 0
        let panel = SuggestionPanel()

        init(_ parent: AddressField) { self.parent = parent }

        /// The field editor took or gave up the keys, typed into or not.
        func focusChanged(_ isFocused: Bool) {
            if parent.isEditing != isFocused { parent.isEditing = isFocused }
        }

        func controlTextDidEndEditing(_ notification: Notification) { focusChanged(false) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.suggestions?.update(field.stringValue)
        }

        /// The row picked, then the field stops editing as after Return.
        func choose(_ row: Suggestion, in control: NSControl) {
            parent.choose(row)
            if parent.endsEditingOnSubmit { endEditing(control) }
        }

        /// While the list shows rows, ↑ / ↓ move its highlight and Esc closes it; Return opens the highlighted row,
        /// else submits; Esc with no list gives up the edit. Return and that Esc stop the editing.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let list = parent.suggestions.flatMap { $0.rows.isEmpty ? nil : $0 }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                guard let list else { return false }
                list.moveDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let list else { return false }
                list.moveUp()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if let list, let index = list.highlighted, list.rows.indices.contains(index) {
                    choose(list.rows[index], in: control)
                    return true
                }
                parent.submit()
                if parent.endsEditingOnSubmit { endEditing(control) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if let list {
                    list.dismiss()
                } else {
                    endEditing(control)
                }
                return true
            default: return false
            }
        }

        private func endEditing(_ control: NSControl) {
            if control.currentEditor() != nil { control.window?.makeFirstResponder(nil) }
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
