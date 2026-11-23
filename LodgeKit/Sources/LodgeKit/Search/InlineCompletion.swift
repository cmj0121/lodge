#if os(macOS)
import AppKit

/// The completion a field editor shows after the text typed, its added part selected. Putting it in and dropping it
/// are ordinary edits the undo stack records, the completion a group of its own, so ⌘Z first takes the completion
/// back, then the typing; a key typed over it takes it back with undo first, so no undo shows it again as text. It
/// counts as shown only while the text and selection are just as `complete` left them; any edit of the user's
/// forgets it.
@MainActor public final class InlineCompletion {
    /// True while it changes the text itself, so the notifications that causes are no edit of the user's.
    public private(set) var isChanging = false
    /// The text as the user's last edit left it.
    private var typed = ""
    /// That edit was typed at the end of the text, with no marked text left, so it may complete.
    private var mayComplete = false
    /// The text and selected range `complete` left.
    private var shown: (text: String, range: NSRange)?

    public init() {}

    /// The host put text in the field, or the field took or gave up the keys: nothing was typed, so nothing
    /// completes.
    public func restart() {
        mayComplete = false
        shown = nil
    }

    /// The user's edit is made; it may complete when typed characters made it, the caret is at the end and no
    /// input method is composing.
    public func didEdit(in view: NSTextView, wasTyped: Bool) {
        typed = view.string
        shown = nil
        mayComplete =
            wasTyped && !view.hasMarkedText()
            && view.selectedRange() == NSRange(location: length(typed), length: 0)
    }

    /// The completion's range while it shows, still selected as put in.
    public func shown(in view: NSTextView) -> NSRange? {
        guard let shown, view.string == shown.text, view.selectedRange() == shown.range, !view.hasMarkedText()
        else { return nil }
        return shown.range
    }

    /// Shows `completion` after what was typed with the added part selected, in place of one already shown, when the
    /// last edit may complete and the view still shows just that (or that and a completion).
    public func complete(to completion: String?, in view: NSTextView) {
        guard mayComplete, !view.hasMarkedText(), let completion, completion.hasPrefix(typed),
            completion != view.string
        else { return }
        let typedLength = length(typed)
        let showsTyped = view.string == typed && view.selectedRange() == NSRange(location: typedLength, length: 0)
        guard let range = showsTyped ? NSRange(location: typedLength, length: 0) : shown(in: view) else { return }
        let added = String(completion.dropFirst(typed.count))
        guard change(range, to: added, in: view) else { return }
        let selected = NSRange(location: typedLength, length: length(added))
        view.setSelectedRange(selected)
        shown = (view.string, selected)
    }

    /// Completes to what `completion` gives on the next run-loop pass, after the undo manager closed the group of
    /// the key typed, so the completion is an undo group of its own and ⌘Z takes it back before the typing.
    public func completeLater(to completion: @escaping @MainActor () -> String?, in view: NSTextView) {
        nonisolated(unsafe) let run = { [weak self, weak view] in
            guard let self, let view else { return }
            complete(to: completion(), in: view)
        }
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { run() } }
    }

    /// Before a key or marked text goes in over the completion: takes it back with undo, its own undo group being the
    /// last, so the key meets just what was typed and no later undo brings the completion back as text. When that
    /// undo turns out to be some other change's, redo puts it back. Its undo and redo are no edits of the user's: the
    /// key that follows is.
    public func retract(in view: NSTextView) {
        guard let range = shown(in: view), let undoManager = view.undoManager, undoManager.canUndo else { return }
        let expected = (view.string as NSString).replacingCharacters(in: range, with: "")
        isChanging = true
        defer { isChanging = false }
        undoManager.undo()
        if view.string == expected { shown = nil } else { undoManager.redo() }
    }

    /// Takes the completion out as an edit undo records, leaving what was typed; nothing completes until the next
    /// typed character.
    public func drop(in view: NSTextView) {
        mayComplete = false
        guard let range = shown(in: view) else { return }
        shown = nil
        if change(range, to: "", in: view) { view.setSelectedRange(NSRange(location: range.location, length: 0)) }
        typed = view.string
    }

    /// Accepts the completion, the caret at its end; false when none shows.
    public func accept(in view: NSTextView) -> Bool {
        guard shown(in: view) != nil else { return false }
        restart()
        typed = view.string
        view.setSelectedRange(NSRange(location: length(view.string), length: 0))
        return true
    }

    /// Changes the text as any recorded edit does, in an undo group it closes itself when none is open, so nothing
    /// recorded after it in the same run-loop pass joins its group; false when the view refuses it.
    private func change(_ range: NSRange, to text: String, in view: NSTextView) -> Bool {
        isChanging = true
        defer { isChanging = false }
        let undoManager = view.undoManager
        let groups = undoManager?.groupingLevel == 0
        if groups { undoManager?.beginUndoGrouping() }
        defer { if groups { undoManager?.endUndoGrouping() } }
        guard view.shouldChangeText(in: range, replacementString: text) else { return false }
        view.replaceCharacters(in: range, with: text)
        view.didChangeText()
        return true
    }

    private func length(_ text: String) -> Int { (text as NSString).length }
}

/// A text view that tells typed characters from every other edit, so only typing completes, and has `inline` take
/// a completion back before a key or marked text goes in over it.
open class CompletingTextView: NSTextView {
    /// The field's completion.
    public weak var inline: InlineCompletion?
    /// Typed characters are going in, so the edit they make may complete.
    public private(set) var isTyping = false

    /// Typed text comes here; a paste, a drop, a deletion or undo do not.
    override open func insertText(_ string: Any, replacementRange: NSRange) {
        inline?.retract(in: self)
        isTyping = true
        defer { isTyping = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    override open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inline?.retract(in: self)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}
#endif
