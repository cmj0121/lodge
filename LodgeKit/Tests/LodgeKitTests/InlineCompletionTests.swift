import AppKit
import Testing

@testable import LodgeKit

/// A real `CompletingTextView` with its own undo manager, its delegate completing each edit as the address field's
/// does; each typed character, undo and redo is one step unless a test groups by event.
@MainActor @Suite struct InlineCompletionTests {
    private final class Host: NSObject, NSTextViewDelegate {
        let undo: UndoManager
        let inline: InlineCompletion
        /// What the field's suggestions complete the typed text to.
        let candidates = [SuggestionCandidate(url: URL(string: "https://github.com/")!, title: "GitHub")]

        init(_ inline: InlineCompletion) {
            undo = UndoManager()
            self.inline = inline
            super.init()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard !inline.isChanging, let view = notification.object as? CompletingTextView else { return }
            inline.didEdit(in: view, wasTyped: view.isTyping)
            inline.complete(to: SuggestionRanker.completion(for: inline.typed, among: candidates), in: view)
        }
    }

    private let inline = InlineCompletion()
    private let host: Host
    private let view = CompletingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))

    init() {
        host = Host(inline)
        host.undo.groupsByEvent = false
        view.delegate = host
        view.allowsUndo = true
        view.isFieldEditor = true
        view.inline = inline
        view.observeUndo()
    }

    private var completion: String? { SuggestionRanker.completion(for: inline.typed, among: host.candidates) }

    /// One step the undo stack records as one group, as one key press or menu command makes.
    private func step(_ action: () -> Void) {
        host.undo.beginUndoGrouping()
        action()
        host.undo.endUndoGrouping()
    }

    private func type(_ text: String) {
        step { view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    private func undo() { host.undo.undo() }

    private func redo() { host.undo.redo() }

    @Test func typingShowsTheCompletionSelected() {
        type("g")
        #expect(view.string == "github.com")
        #expect(view.selectedRange() == NSRange(location: 1, length: 9))
        type("i")
        #expect(view.string == "github.com")
        #expect(view.selectedRange() == NSRange(location: 2, length: 8))
        type("x")
        #expect(view.string == "gix")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func undoNeverLeavesCompletionText() {
        type("g")
        type("i")
        undo()
        #expect(view.string == "g")
        undo()
        #expect(view.string == "")
        #expect(!host.undo.canUndo)
        redo()
        #expect(view.string == "g")
        redo()
        #expect(view.string == "gi")
        #expect(!host.undo.canRedo)
    }

    @Test func dropLeavesWhatWasTypedAndStopsCompleting() {
        type("gi")
        inline.drop(in: view)
        #expect(view.string == "gi")
        inline.complete(to: completion, in: view)
        #expect(view.string == "gi")
        type("t")
        #expect(view.string == "github.com")
        undo()
        #expect(view.string == "gi")
    }

    @Test func acceptMakesTheCompletionTextUndoCanTakeBack() {
        type("gi")
        var accepted = false
        step { accepted = inline.accept(in: view) }
        #expect(accepted)
        #expect(view.string == "github.com")
        #expect(view.selectedRange() == NSRange(location: 10, length: 0))
        #expect(inline.typed == "github.com")
        #expect(!inline.accept(in: view))
        host.undo.undo()
        #expect(view.string == "gi")
    }

    @Test func untypedEditsAndAnEditShortOfTheEndDoNotComplete() {
        view.string = "g"
        inline.didEdit(in: view, wasTyped: false)
        inline.complete(to: completion, in: view)
        #expect(view.string == "g")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        inline.didEdit(in: view, wasTyped: true)
        inline.complete(to: completion, in: view)
        #expect(view.string == "g")
    }

    @Test func markedTextNeverCompletes() {
        step {
            view.setMarkedText(
                "g", selectedRange: NSRange(location: 1, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        inline.didEdit(in: view, wasTyped: true)
        inline.complete(to: completion, in: view)
        #expect(view.string == "g")
        #expect(view.hasMarkedText())
    }

    @Test func selectAllMakesTheCompletionTextAndUndoLeavesNoneBehind() {
        type("gi")
        step { view.selectAll(nil) }
        #expect(view.string == "github.com")
        #expect(inline.shown(in: view) == nil)
        type("x")
        #expect(view.string == "x")
        undo()
        #expect(view.string == "github.com")
        undo()
        #expect(view.string == "gi")
        undo()
        #expect(view.string == "")
    }

    @Test func aClickOffTheCompletionKeepsItAsText() {
        type("gi")
        step { view.setSelectedRange(NSRange(location: 0, length: 0)) }
        #expect(view.string == "github.com")
        type("x")
        #expect(view.string == "xgithub.com")
        undo()
        undo()
        #expect(view.string == "gi")
    }

    @Test func coalescedTypingUndoesAtOnce() {
        host.undo.groupsByEvent = true
        for character in ["g", "i", "t"] {
            view.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.main.run(until: Date())
        }
        #expect(view.string == "github.com")
        #expect(view.selectedRange() == NSRange(location: 3, length: 7))
        undo()
        #expect(view.string == "")
        #expect(!host.undo.canUndo)
    }
}
