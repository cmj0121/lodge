import Foundation
import JavaScriptCore
import Testing

@testable import LodgeKit

@Suite struct PageWorkTests {
    @Test func aNewPageHoldsNothing() {
        #expect(!PageWork().isHeld)
    }

    @Test func typedHoldsUntilClearedSentOrGone() {
        for end in [PageWork.Signal.cleared(document: "a"), .sent(document: "a"), .gone(document: "a")] {
            var work = PageWork()
            work.apply(.typed(document: "a"))
            #expect(work.isHeld)
            work.apply(end)
            #expect(!work.isHeld, "\(end)")
        }
    }

    @Test func eachDocumentHoldsOnItsOwn() {
        var work = PageWork()
        work.apply(.typed(document: "main"))
        work.apply(.typed(document: "frame"))
        work.apply(.gone(document: "frame"))
        #expect(work.isHeld)
        work.apply(.cleared(document: "other"))
        #expect(work.isHeld)
        work.apply(.sent(document: "main"))
        #expect(!work.isHeld)
    }

    @Test func typingAgainAfterSendingHoldsAgain() {
        var work = PageWork()
        work.apply(.typed(document: "a"))
        work.apply(.sent(document: "a"))
        work.apply(.typed(document: "a"))
        #expect(work.isHeld)
    }

    @Test func resetDropsEveryDocument() {
        var work = PageWork()
        work.apply(.typed(document: "a"))
        work.apply(.typed(document: "b"))
        work.reset()
        #expect(!work.isHeld)
        #expect(work == PageWork())
    }

    @Test func aFormPostHoldsWhileInFlight() {
        var work = PageWork()
        work.formPost(inFlight: true)
        #expect(work.isHeld)
        work.formPost(inFlight: false)
        #expect(!work.isHeld)
        #expect(work == PageWork())
    }

    @Test func aFormPostOutlastsTheCommitThatResetsDocuments() {
        var work = PageWork()
        work.apply(.typed(document: "a"))
        work.formPost(inFlight: true)
        work.reset()
        #expect(work.isHeld)
        work.formPost(inFlight: false)
        #expect(!work.isHeld)
    }

    // MARK: Message bodies

    @Test func decodesEveryKind() {
        #expect(PageWorkScript.signal(from: ["doc": "d", "kind": "typed"]) == .typed(document: "d"))
        #expect(PageWorkScript.signal(from: ["doc": "d", "kind": "cleared"]) == .cleared(document: "d"))
        #expect(PageWorkScript.signal(from: ["doc": "d", "kind": "sent"]) == .sent(document: "d"))
        #expect(PageWorkScript.signal(from: ["doc": "d", "kind": "gone"]) == .gone(document: "d"))
        let bridged: Any = ["doc": "d", "kind": "typed"] as NSDictionary
        #expect(PageWorkScript.signal(from: bridged) == .typed(document: "d"))
    }

    @Test func malformedBodiesGiveNil() {
        let bodies: [Any] = [
            "typed", 1, NSNull(), ["typed"],
            [String: Any](),
            ["doc": "d"],
            ["kind": "typed"],
            ["doc": 1, "kind": "typed"],
            ["doc": "d", "kind": 1],
            ["doc": "d", "kind": "TYPED"],
            ["doc": "d", "kind": "value"],
            ["doc": "", "kind": "typed"],
            ["doc": String(repeating: "x", count: 65), "kind": "typed"],
            ["doc": "d", "kind": "typed", "value": "secret"],
        ]
        for body in bodies {
            #expect(PageWorkScript.signal(from: body) == nil, "\(body)")
        }
    }

    // MARK: The script

    @Test func theScriptPostsOnlyTheDocumentAndKind() {
        let source = PageWorkScript.source
        #expect(source.components(separatedBy: "postMessage(").count == 2)
        #expect(source.contains("postMessage({ doc: doc, kind: kind })"))
        #expect(source.contains("handlers.\(PageWorkScript.handlerName);"))
    }

    @Test func trustedTypingHoldsAndClearingReleases() throws {
        let page = try ScriptPage()
        page.run("var f = field(); f.value = 'my secret'; fire('input', { target: f });")
        #expect(page.kinds == ["typed"])
        page.run("f.value = 'my secret too'; fire('input', { target: f });")
        #expect(page.kinds == ["typed"])
        page.run("f.value = ''; fire('input', { target: f });")
        #expect(page.kinds == ["typed", "cleared"])
        page.expectOnlyDocumentAndKind(notContaining: ["my secret", "my secret too"])
    }

    @Test func untrustedInputAndNonTextFieldsDoNotHold() throws {
        let page = try ScriptPage()
        page.run("var f = field(); f.value = 'x'; fire('input', { target: f, isTrusted: false });")
        page.run("var c = field({ type: 'checkbox', value: 'on' }); fire('input', { target: c });")
        page.run("var r = field({ type: 'RANGE', value: '3' }); fire('input', { target: r });")
        page.run("var b = { nodeType: 1, localName: 'div', isContentEditable: false }; fire('input', { target: b });")
        #expect(page.kinds.isEmpty)
    }

    @Test func textareasContentEditableAndShadowFieldsHold() throws {
        for setup in [
            "var f = field({ localName: 'textarea', value: 'x' }); fire('input', { target: f });",
            "var f = { nodeType: 1, localName: 'div', isContentEditable: true, textContent: 'x', isConnected: true }; fire('input', { target: f });",
            "var f = field({ value: 'x' }); fire('input', { target: { nodeType: 1 }, composedPath: () => [f] });",
        ] {
            let page = try ScriptPage()
            page.run(setup)
            #expect(page.kinds == ["typed"], "\(setup)")
        }
    }

    @Test func untrustedInputStillClearsAFieldEmptiedByThePage() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'x' }); fire('input', { target: f });")
        page.run("f.value = ''; fire('input', { target: f, isTrusted: false });")
        #expect(page.kinds == ["typed", "cleared"])
    }

    @Test func aFieldTheScriptEmptiedClearsOnceThePageIsHidden() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'sent by fetch' }); fire('input', { target: f });")
        page.run("f.value = '';")
        #expect(page.kinds == ["typed"])
        page.run("fire('visibilitychange', {});")
        #expect(page.kinds == ["typed", "cleared"])
        page.expectOnlyDocumentAndKind(notContaining: ["sent by fetch"])
    }

    @Test func hidingAPageWithTextStillHolds() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'draft' }); fire('input', { target: f }); fire('visibilitychange', {});")
        #expect(page.kinds == ["typed"])
    }

    @Test func aRemovedFieldNoLongerHolds() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'x' }); fire('input', { target: f });")
        page.run("f.isConnected = false; fire('focusout', {});")
        #expect(page.kinds == ["typed", "cleared"])
    }

    @Test func aResetFormClearsOnceTheResetIsDone() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'x' }); fire('input', { target: f }); fire('reset', {});")
        #expect(page.kinds == ["typed"])
        page.run("f.value = ''; runTimers();")
        #expect(page.kinds == ["typed", "cleared"])
    }

    @Test func submitSendsAndPagehideGoes() throws {
        let page = try ScriptPage()
        page.run("fire('submit', {}); fire('pagehide', {});")
        #expect(page.kinds.isEmpty)
        page.run("var f = field({ value: 'x' }); fire('input', { target: f }); fire('submit', {});")
        #expect(page.kinds == ["typed", "sent"])
        page.run("fire('input', { target: f }); fire('pagehide', {});")
        #expect(page.kinds == ["typed", "sent", "typed", "gone"])
        page.run("fire('pageshow', { persisted: true });")
        #expect(page.kinds == ["typed", "sent", "typed", "gone", "typed"])
        page.expectOnlyDocumentAndKind(notContaining: ["x"])
    }

    @Test func everyMessageNamesTheSameDocument() throws {
        let page = try ScriptPage()
        page.run("var f = field({ value: 'x' }); fire('input', { target: f }); fire('submit', {});")
        let documents = Set(page.posted.compactMap { $0["doc"] as? String })
        #expect(documents == ["doc-1"])
        let other = try ScriptPage()
        #expect(other.posted.isEmpty)
    }

    @Test func withoutItsHandlerTheScriptDoesNothing() throws {
        let page = try ScriptPage(withHandler: false)
        page.run("var f = field({ value: 'x' }); fire('input', { target: f });")
        #expect(page.posted.isEmpty)
        #expect(page.listenerCount == 0)
    }

    // MARK: beforeunload probe

    @Test func theProbeSeesAPreventedOrReturnValuedEvent() throws {
        let cases: [(String, Bool)] = [
            ("", false),
            ("window.addEventListener('beforeunload', () => {});", false),
            ("window.addEventListener('beforeunload', (e) => e.preventDefault());", true),
            ("window.addEventListener('beforeunload', (e) => { e.returnValue = 'leave?'; });", true),
        ]
        for (listener, prompts) in cases {
            let page = try ScriptPage()
            page.run(listener)
            #expect(page.probe() == prompts, "\(listener)")
        }
    }
}

/// A page stand-in for running `PageWorkScript` in JavaScriptCore: a `window` collecting listeners, a `lodgeWork`
/// handler recording what is posted, numbered document ids, and fields as plain objects.
private final class ScriptPage {
    private let context: JSContext

    init(withHandler: Bool = true) throws {
        context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript threw: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(
            """
            var posted = [];
            var listeners = {};
            var timers = [];
            var ids = 0;
            var crypto = { randomUUID: function () { ids += 1; return 'doc-' + ids; } };
            function setTimeout(fn) { timers.push(fn); }
            function runTimers() { var run = timers; timers = []; run.forEach(function (fn) { fn(); }); }
            var window = {
              addEventListener: function (type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
              dispatchEvent: function (e) {
                (listeners[e.type] || []).forEach(function (fn) { fn(e); });
                return !e.defaultPrevented;
              },
            };
            \(withHandler ? "window.webkit = { messageHandlers: { lodgeWork: { postMessage: function (m) { posted.push(m); } } } };" : "")
            var document = {
              createEvent: function () {
                return {
                  type: '', defaultPrevented: false, returnValue: '',
                  initEvent: function (type) { this.type = type; },
                  preventDefault: function () { this.defaultPrevented = true; },
                };
              },
            };
            function field(props) {
              return Object.assign(
                { nodeType: 1, localName: 'input', type: 'text', value: '', isConnected: true, isContentEditable: false },
                props || {});
            }
            function fire(type, props) {
              var e = Object.assign({ type: type, isTrusted: true, target: null }, props || {});
              (listeners[type] || []).slice().forEach(function (fn) { fn(e); });
            }
            """)
        context.evaluateScript(PageWorkScript.source)
    }

    func run(_ script: String) { context.evaluateScript(script) }

    var posted: [[String: Any]] {
        (context.objectForKeyedSubscript("posted").toArray() ?? []).compactMap { $0 as? [String: Any] }
    }

    var kinds: [String] { posted.compactMap { $0["kind"] as? String } }

    var listenerCount: Int {
        Int(context.evaluateScript("Object.keys(listeners).length").toInt32())
    }

    func probe() -> Bool {
        context.evaluateScript("(function () {\n\(PageWorkScript.beforeUnloadProbe)\n})()").toBool()
    }

    /// Every message has exactly `doc` and `kind`, decodes, and carries none of `values`.
    func expectOnlyDocumentAndKind(notContaining values: [String]) {
        for message in posted {
            #expect(Set(message.keys) == ["doc", "kind"])
            #expect(PageWorkScript.signal(from: message) != nil)
            for value in values {
                #expect(!message.values.contains { ($0 as? String) == value })
            }
        }
    }
}
