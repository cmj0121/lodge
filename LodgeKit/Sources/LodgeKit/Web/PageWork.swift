/// What keeps one tab's page awake beyond today's holds (playback, capture, fullscreen, popup pair).
public struct PageWork: Equatable, Sendable {
    /// From the isolated-world script; `document` is the script's own per-document `crypto.randomUUID()`.
    public enum Signal: Equatable, Sendable {
        /// Trusted `input` in an editable field or contenteditable.
        case typed(document: String)
        /// Every field edited in that document is empty again.
        case cleared(document: String)
        /// `submit` in that document.
        case sent(document: String)
        /// `pagehide` of that document.
        case gone(document: String)
    }

    /// Documents with typed text not yet cleared, sent or gone.
    private var typed: Set<String> = []
    private var isFormPostInFlight = false

    public init() {}

    public mutating func apply(_ signal: Signal) {
        switch signal {
        case .typed(let document): typed.insert(document)
        case .cleared(let document), .sent(let document), .gone(let document): typed.remove(document)
        }
    }

    /// Main-frame navigation with `.formSubmitted`/`.formResubmitted` began (true) / loading ended (false).
    public mutating func formPost(inFlight: Bool) {
        isFormPostInFlight = inFlight
    }

    /// The web content process terminated, or the main frame committed a new document: all signals drop.
    public mutating func reset() {
        typed = []
    }

    /// Any document typed and not cleared/sent/gone, or a form POST in flight.
    public var isHeld: Bool { !typed.isEmpty || isFormPostInFlight }
}

/// The isolated-world script behind `PageWork`, and how its messages read. The script sends no field values: it keeps,
/// inside the page, which fields it saw edited and reports only whether any of them still holds text.
public enum PageWorkScript {
    /// `WKContentWorld.world(name:)`: the page cannot see or tamper with the script, nor post to its handler.
    public static let worldName = "lodge.work"
    public static let handlerName = "lodgeWork"

    /// Injected at document start, `forMainFrameOnly: false`, so every frame reports for its own document.
    public static let source = """
        (() => {
          const handlers = window.webkit && window.webkit.messageHandlers;
          const handler = handlers && handlers.\(handlerName);
          if (!handler) { return; }
          const doc = (typeof crypto !== 'undefined' && crypto.randomUUID)
            ? crypto.randomUUID()
            : Math.random().toString(36).slice(2) + Date.now().toString(36);
          const post = (kind) => {
            try { handler.postMessage({ doc: doc, kind: kind }); } catch (_) {}
          };
          const unwatched = new Set(['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range',
            'reset', 'submit']);
          const isField = (el) => {
            if (!el || el.nodeType !== 1) { return false; }
            if (el.isContentEditable) { return true; }
            if (el.localName === 'textarea') { return true; }
            return el.localName === 'input' && !unwatched.has(String(el.type).toLowerCase());
          };
          const isEmpty = (el) => !el.isConnected
            || (el.isContentEditable ? el.textContent.length === 0 : el.value.length === 0);
          const edited = new Set();
          let holding = false;
          const settle = () => {
            for (const el of edited) { if (isEmpty(el)) { edited.delete(el); } }
            const now = edited.size > 0;
            if (now !== holding) {
              holding = now;
              post(now ? 'typed' : 'cleared');
            }
          };
          const target = (e) => (e.composedPath && e.composedPath()[0]) || e.target;
          const options = { capture: true, passive: true };
          window.addEventListener('input', (e) => {
            const el = target(e);
            if (e.isTrusted && isField(el)) { edited.add(el); }
            settle();
          }, options);
          window.addEventListener('change', settle, options);
          window.addEventListener('focusout', settle, options);
          // A page that empties a field itself (sent by fetch) is caught at the latest when the page is hidden.
          window.addEventListener('visibilitychange', settle, options);
          window.addEventListener('reset', () => { setTimeout(settle, 0); }, options);
          window.addEventListener('submit', () => {
            edited.clear();
            if (holding) {
              holding = false;
              post('sent');
            }
          }, options);
          window.addEventListener('pagehide', () => { if (holding) { post('gone'); } }, options);
          window.addEventListener('pageshow', (e) => { if (e.persisted && holding) { post('typed'); } }, options);
        })();
        """

    /// Decodes a message body `{doc: String, kind: "typed"|"cleared"|"sent"|"gone"}`; anything else is nil.
    public static func signal(from body: Any) -> PageWork.Signal? {
        guard let body = body as? [String: Any], body.count == 2,
            let document = body["doc"] as? String, (1...64).contains(document.count),
            let kind = body["kind"] as? String
        else { return nil }
        switch kind {
        case "typed": return .typed(document: document)
        case "cleared": return .cleared(document: document)
        case "sent": return .sent(document: document)
        case "gone": return .gone(document: document)
        default: return nil
        }
    }

    /// Best-effort `beforeunload` probe run in the isolated world right before a release decision; returns
    /// whether a synthetic BeforeUnloadEvent was prevented / given a returnValue. A function body for
    /// `callAsyncJavaScript`. It runs the page's handlers, and a page checking `isTrusted` slips through.
    public static let beforeUnloadProbe = """
        const event = document.createEvent('BeforeUnloadEvent');
        event.initEvent('beforeunload', false, true);
        const proceeded = window.dispatchEvent(event);
        return !proceeded || event.defaultPrevented
          || (typeof event.returnValue === 'string' && event.returnValue.length > 0);
        """
}
