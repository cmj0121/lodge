import AppKit
import Testing

@testable import LodgeKit

/// A real `CompletingTextView` with its own undo manager grouping by event, as a window's does; each run-loop pass
/// between actions ends an event. Its delegate completes as the address field's does: each edit updates the
/// suggestions, and the completion goes in on the next run-loop pass, reading the suggestions as they are then.
@MainActor @Suite struct InlineCompletionTests {
    @MainActor private final class Host: NSObject, NSTextViewDelegate {
        let undo: UndoManager
        let inline: InlineCompletion
        var completes = true
        let candidates = [SuggestionCandidate(url: URL(string: "https://github.com/")!, title: "GitHub")]
        /// The suggestions' completion for the last edit's text.
        private(set) var suggested: String?
        /// How many edits of the user's it was told of.
        private(set) var edits = 0

        init(_ inline: InlineCompletion) {
            undo = UndoManager()
            self.inline = inline
            super.init()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func completion(for text: String) -> String? { SuggestionRanker.completion(for: text, among: candidates) }

        func textDidChange(_ notification: Notification) {
            guard !inline.isChanging, let view = notification.object as? CompletingTextView else { return }
            inline.didEdit(in: view, wasTyped: view.isTyping)
            edits += 1
            suggested = completes ? completion(for: view.string) : nil
            inline.completeLater(to: { [weak self] in self?.suggested }, in: view)
        }
    }

    /// Something else in the window recording undo on the same undo manager, as a window's shared one is.
    @MainActor private final class Unrelated: NSObject {
        let undo: UndoManager
        private(set) var value = 0

        init(_ undo: UndoManager) { self.undo = undo }

        @objc func add(_ amount: NSNumber) {
            value += amount.intValue
            undo.registerUndo(withTarget: self, selector: #selector(add(_:)), object: NSNumber(value: -amount.intValue))
        }
    }

    private let inline = InlineCompletion()
    private let host: Host
    private let view = CompletingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
    private let none = NSRange(location: NSNotFound, length: 0)

    init() {
        host = Host(inline)
        host.undo.groupsByEvent = true
        view.delegate = host
        view.allowsUndo = true
        view.isFieldEditor = true
        view.inline = inline
    }

    /// Ends the event as between key presses: turns the main run loop, without sleeping, until no undo group is
    /// open. The undo manager closes the event's group as a turn starts; a completion waiting for the next turn goes
    /// in during it and opens a group of its own, which only the turn after closes. A fixed wait did not always reach
    /// that second turn under load, so the next action joined the completion's group (#27).
    private func pass() {
        var turns = 0
        repeat {
            _ = CFRunLoopRunInMode(.defaultMode, 0, false)
            turns += 1
        } while host.undo.groupingLevel > 0 && turns < 100
    }

    /// One key press or menu command, in an event of its own.
    private func step(_ action: () -> Void) {
        action()
        pass()
    }

    /// Each character a key press of its own.
    private func type(_ text: String) {
        for character in text { step { view.insertText(String(character), replacementRange: none) } }
    }

    private func undo() { step { host.undo.undo() } }

    private func redo() { step { host.undo.redo() } }

    private func expect(
        _ text: String, selected range: NSRange, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(view.string == text, sourceLocation: sourceLocation)
        #expect(view.selectedRange() == range, sourceLocation: sourceLocation)
    }

    /// Undo goes all the way back to the empty field and redo all the way forward to the text it started from,
    /// twice, meeting `history` (newest first) both ways; undo and redo stay usable throughout.
    private func expectIntactHistory(_ history: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let end = view.string
        for _ in 0..<2 {
            var seen = [view.string]
            while host.undo.canUndo {
                undo()
                seen.append(view.string)
            }
            #expect(seen == history, sourceLocation: sourceLocation)
            #expect(host.undo.canRedo, sourceLocation: sourceLocation)
            var redone = [view.string]
            while host.undo.canRedo {
                redo()
                redone.append(view.string)
            }
            #expect(redone == history.reversed(), sourceLocation: sourceLocation)
            #expect(view.string == end, sourceLocation: sourceLocation)
            #expect(host.undo.canUndo, sourceLocation: sourceLocation)
        }
    }

    @Test func typingCompletesToTheSuggestionWithItsAddedPartSelected() {
        type("g")
        expect("github.com", selected: NSRange(location: 1, length: 9))
        type("i")
        expect("github.com", selected: NSRange(location: 2, length: 8))
        type("x")
        expect("gix", selected: NSRange(location: 3, length: 0))
    }

    /// The completion is an undo group of its own: the first ⌘Z takes back just it and leaves "gi". "i", typed over
    /// "g"'s completion, took that completion back with undo first, so the next ⌘Z leaves "g", not "github.com"; the
    /// undo ends AppKit's typing coalescing, so each key typed over a completion is one ⌘Z.
    @Test func undoTakesBackTheCompletionThenTheTyping() {
        type("gi")
        undo()
        expect("gi", selected: NSRange(location: 2, length: 0))
        #expect(inline.shown(in: view) == nil)
        undo()
        expect("g", selected: NSRange(location: 1, length: 0))
        undo()
        expect("", selected: NSRange(location: 0, length: 0))
        #expect(!host.undo.canUndo)
        redo()
        #expect(view.string == "g")
        redo()
        #expect(view.string == "gi")
        redo()
        #expect(view.string == "github.com")
        #expect(!host.undo.canRedo)
        expectIntactHistory(["github.com", "gi", "g", ""])
    }

    /// Taking the completion back before a key is no edit of the user's: only the key is.
    @Test func aKeyOverTheCompletionIsTheOnlyEdit() {
        type("g")
        let before = host.edits
        type("i")
        #expect(host.edits == before + 1)
        expect("github.com", selected: NSRange(location: 2, length: 8))
    }

    /// When the newest undo group is some other change's, not the completion's, taking the completion back redoes
    /// that change and leaves the key to replace the completion as any selection. Undo then meets "g"'s completion
    /// as text the user saw, the other change in its place, and every state on the way back and forth again.
    @Test func aKeyOverTheCompletionLeavesAnotherChangesUndoAlone() {
        let unrelated = Unrelated(host.undo)
        type("g")
        step { unrelated.add(1) }
        type("i")
        expect("github.com", selected: NSRange(location: 2, length: 8))
        #expect(unrelated.value == 1)
        undo()
        expect("gi", selected: NSRange(location: 2, length: 0))
        undo()
        #expect(view.string == "github.com")
        #expect(unrelated.value == 1)
        undo()
        #expect(view.string == "github.com")
        #expect(unrelated.value == 0)
        undo()
        undo()
        #expect(view.string == "")
        #expect(!host.undo.canUndo)
        for _ in 0..<5 { redo() }
        #expect(view.string == "github.com")
        #expect(unrelated.value == 1)
        #expect(!host.undo.canRedo)
        expectIntactHistory(["github.com", "gi", "github.com", "github.com", "g", ""])
        #expect(unrelated.value == 1)
    }

    /// Keys typed before the completion goes in coalesce, and the completion that lands reads the suggestions for
    /// all of them; a completion that no longer fits what was typed completes nothing.
    @Test func aKeyTypedBeforeTheCompletionLandsIsCompletedWith() {
        view.insertText("g", replacementRange: none)
        view.insertText("i", replacementRange: none)
        pass()
        expect("github.com", selected: NSRange(location: 2, length: 8))
        expectIntactHistory(["github.com", "gi", ""])
        undo()
        undo()
        view.insertText("g", replacementRange: none)
        view.insertText("x", replacementRange: none)
        inline.complete(to: "github.com", in: view)
        pass()
        expect("gx", selected: NSRange(location: 2, length: 0))
        expectIntactHistory(["gx", ""])
    }

    @Test func typingWithNoCompletionCoalescesIntoOneUndo() {
        type("xyz")
        expect("xyz", selected: NSRange(location: 3, length: 0))
        undo()
        expect("", selected: NSRange(location: 0, length: 0))
        #expect(!host.undo.canUndo)
        redo()
        expect("xyz", selected: NSRange(location: 3, length: 0))
        expectIntactHistory(["xyz", ""])
    }

    /// #20, first case: undo and redo after deleting a selected suffix that is no completion. Undo puts the suffix
    /// back with the caret after it, as AppKit does for any deletion.
    @Test func undoAfterDeletingASelectedSuffixRestoresItExactly() {
        host.completes = false
        type("github")
        step { view.setSelectedRange(NSRange(location: 3, length: 3)) }
        step { view.deleteBackward(nil) }
        expect("git", selected: NSRange(location: 3, length: 0))
        undo()
        expect("github", selected: NSRange(location: 6, length: 0))
        #expect(host.undo.canRedo)
        redo()
        expect("git", selected: NSRange(location: 3, length: 0))
        #expect(!host.undo.canRedo)
        expectIntactHistory(["git", "github", ""])
    }

    /// #20, second case: leaving the field while a completion shows keeps it as text undo has recorded.
    @Test func resigningWithACompletionShownKeepsUndoIntact() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))
        type("gi")
        #expect(window.makeFirstResponder(nil))
        inline.restart()
        #expect(view.string == "github.com")
        #expect(inline.shown(in: view) == nil)
        expectIntactHistory(["github.com", "gi", "g", ""])
        undo()
        expect("gi", selected: NSRange(location: 2, length: 0))
        #expect(host.undo.canRedo)
    }

    @Test func selectAllThenTypingReplacesEverythingAndUndoesBack() {
        type("gi")
        step { view.selectAll(nil) }
        expect("github.com", selected: NSRange(location: 0, length: 10))
        #expect(inline.shown(in: view) == nil)
        type("x")
        expect("x", selected: NSRange(location: 1, length: 0))
        expectIntactHistory(["x", "github.com", "gi", "g", ""])
    }

    @Test func acceptPutsTheCaretAfterTheCompletion() {
        type("gi")
        #expect(inline.accept(in: view))
        expect("github.com", selected: NSRange(location: 10, length: 0))
        #expect(!inline.accept(in: view))
        inline.complete(to: "github.com/cmj", in: view)
        #expect(view.string == "github.com")
        type("/")
        expect("github.com/", selected: NSRange(location: 11, length: 0))
        expectIntactHistory(["github.com/", "github.com", "gi", "g", ""])
    }

    /// ⌫ deletes the selected completion as any selection, and the deletion completes nothing.
    @Test func deleteDropsTheCompletionAndDoesNotCompleteAgain() {
        type("gi")
        step { view.deleteBackward(nil) }
        expect("gi", selected: NSRange(location: 2, length: 0))
        #expect(inline.shown(in: view) == nil)
        inline.complete(to: host.completion(for: view.string), in: view)
        #expect(view.string == "gi")
        type("t")
        expect("github.com", selected: NSRange(location: 3, length: 7))
        expectIntactHistory(["github.com", "git", "github.com", "gi", "g", ""])
    }

    /// The location prompt's Esc: the completion goes as an edit undo records, and nothing completes until typing.
    @Test func dropTakesTheCompletionOutUntilTheNextKey() {
        type("gi")
        step { inline.drop(in: view) }
        expect("gi", selected: NSRange(location: 2, length: 0))
        inline.complete(to: host.completion(for: view.string), in: view)
        #expect(view.string == "gi")
        undo()
        expect("github.com", selected: NSRange(location: 10, length: 0))
        #expect(inline.shown(in: view) == nil)
        redo()
        expect("gi", selected: NSRange(location: 2, length: 0))
        expectIntactHistory(["gi", "github.com", "gi", "g", ""])
    }

    /// Composing completes nothing; the composition committed is typing and completes. Marked text over a completion
    /// takes the completion back first, as a key does. AppKit records the composition only once committed.
    @Test func markedTextNeverCompletes() {
        step { view.setMarkedText("g", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        expect("g", selected: NSRange(location: 1, length: 0))
        #expect(view.hasMarkedText())
        inline.complete(to: host.completion(for: view.string), in: view)
        #expect(view.string == "g")
        step { view.insertText("g", replacementRange: none) }
        #expect(!view.hasMarkedText())
        expect("github.com", selected: NSRange(location: 1, length: 9))
        step { view.setMarkedText("i", selectedRange: NSRange(location: 1, length: 0), replacementRange: none) }
        expect("gi", selected: NSRange(location: 2, length: 0))
        #expect(view.hasMarkedText())
        #expect(inline.shown(in: view) == nil)
        step { view.insertText("i", replacementRange: none) }
        #expect(!view.hasMarkedText())
        expect("github.com", selected: NSRange(location: 2, length: 8))
        expectIntactHistory(["github.com", "gi", "g", ""])
    }
}
