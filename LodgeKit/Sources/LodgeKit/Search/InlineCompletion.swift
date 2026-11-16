import AppKit

/// The completion a field editor shows after the text typed, its added part selected. The completion never enters
/// the undo stack: it goes in and out unrecorded, and is taken out before every recorded edit (typed characters,
/// marked text, undo, redo), so each recorded edit meets the text as it was typed. Any other edit or selection
/// change first makes it recorded text. `CompletingTextView` calls it at those points.
@MainActor public final class InlineCompletion {
    /// The text as the user left it, without the completion shown after it.
    public private(set) var typed = ""
    /// True while it changes the text or the selection itself, so the notifications and selection changes that
    /// causes are no edit of the user's.
    public private(set) var isChanging = false
    /// The last edit typed at the end of the text, with no marked text left, so it may complete.
    private var mayComplete = false

    public init() {}

    /// The host put `text` in the field, or the field took or gave up the keys: nothing was typed, so nothing
    /// completes.
    public func restart(from text: String) {
        typed = text
        mayComplete = false
    }

    /// The user's edit is made; it may complete when typed characters made it, the caret is at the end and no
    /// input method is composing.
    public func didEdit(in view: NSTextView, wasTyped: Bool) {
        typed = view.string
        mayComplete =
            wasTyped && !view.hasMarkedText()
            && view.selectedRange() == NSRange(location: length(typed), length: 0)
    }

    /// The completion's range while it shows after what was typed, still selected as put in.
    public func shown(in view: NSTextView) -> NSRange? {
        let typedLength = length(typed)
        let total = length(view.string)
        guard total > typedLength, view.string.hasPrefix(typed),
            view.selectedRange() == NSRange(location: typedLength, length: total - typedLength)
        else { return nil }
        return view.selectedRange()
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
        changing {
            change(range, to: added, in: view)
            view.setSelectedRange(NSRange(location: typedLength, length: length(added)))
        }
    }

    /// Takes the completion out, leaving what was typed; nothing completes until the next typed character.
    public func drop(in view: NSTextView) {
        mayComplete = false
        strip(in: view)
    }

    /// Before typed characters, marked text, undo or redo: takes the completion out unrecorded, the caret after what
    /// was typed, so the recorded edit meets the text it was made on.
    public func strip(in view: NSTextView) {
        guard let range = shown(in: view) else { return }
        changing {
            change(range, to: "", in: view)
            view.setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    /// Before any other edit or caret move: the completion becomes text as an edit undo records, still selected.
    public func commit(in view: NSTextView) {
        guard let range = shown(in: view) else { return }
        let added = (view.string as NSString).substring(with: range)
        changing {
            strip(in: view)
            let inserted = NSRange(location: range.location, length: 0)
            if view.shouldChangeText(in: inserted, replacementString: added) {
                view.replaceCharacters(in: inserted, with: added)
                view.didChangeText()
            }
            view.setSelectedRange(range)
        }
        restart(from: view.string)
    }

    /// Accepts the completion as recorded text, the caret at its end; false when none shows.
    public func accept(in view: NSTextView) -> Bool {
        guard shown(in: view) != nil else { return false }
        changing {
            commit(in: view)
            view.setSelectedRange(NSRange(location: length(view.string), length: 0))
        }
        return true
    }

    /// Changes the text with undo registration off, then tells the view's delegate as for any change.
    private func change(_ range: NSRange, to text: String, in view: NSTextView) {
        view.undoManager?.disableUndoRegistration()
        defer { view.undoManager?.enableUndoRegistration() }
        view.textStorage?.replaceCharacters(in: range, with: text)
        view.didChangeText()
    }

    private func changing(_ body: () -> Void) {
        let was = isChanging
        isChanging = true
        defer { isChanging = was }
        body()
    }

    private func length(_ text: String) -> Int { (text as NSString).length }
}

/// A text view that keeps `inline`'s completion out of its undo stack: it takes the completion out before typed
/// characters, marked text, undo and redo, and makes it recorded text before any other edit or selection change
/// (a click, Select All, cut, paste, a drop, a transformation, a spelling correction, a service). Undo and redo are
/// watched while it is first responder.
open class CompletingTextView: NSTextView {
    /// The field's completion.
    public weak var inline: InlineCompletion?
    /// Typed characters are going in, so the edit they make may complete.
    public private(set) var isTyping = false
    private var undoObservers: [NSObjectProtocol] = []

    isolated deinit { stopObservingUndo() }

    override open func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { observeUndo() }
        return became
    }

    override open func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopObservingUndo() }
        return resigned
    }

    /// Typed text comes here; a paste, a drop, a deletion or undo do not.
    override open func insertText(_ string: Any, replacementRange: NSRange) {
        inline?.strip(in: self)
        isTyping = true
        defer { isTyping = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Marked text replaces the completion as typing does.
    override open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inline?.strip(in: self)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override open func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        commitUnlessOwn()
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override open func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool
    ) {
        if ranges != selectedRanges { commitUnlessOwn() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    /// Makes a completion shown recorded text, unless the change under way is the completion's own or typing's,
    /// which took it out first.
    private func commitUnlessOwn() {
        guard let inline, !inline.isChanging else { return }
        inline.commit(in: self)
    }

    /// Starts watching undo and redo, which must meet the text without the completion, as every edit they replay
    /// was made. A first responder calls it itself.
    public func observeUndo() {
        stopObservingUndo()
        guard let undoManager else { return }
        undoObservers = [NSNotification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inline?.strip(in: self)
                }
            }
        }
    }

    private func stopObservingUndo() {
        for observer in undoObservers { NotificationCenter.default.removeObserver(observer) }
        undoObservers = []
    }
}
