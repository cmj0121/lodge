import Foundation

/// The isolated-world script behind the mini player (#36): it finds a page's video in any frame, reports it, and makes
/// it fill the view while the view is in the mini player.
///
/// Every frame, cross-origin ones included, watches its own `<video>` elements of at least `minimumSide`² area and
/// reports the one that ranks first (`rank`) straight to the app, under a random id of its document; the app keeps a
/// tab's reports in `Reports` and ranks them. Frames never tell one another what plays: a page sees nothing of it.
///
/// Filling runs only while a view goes into the mini player, one hop at a time: the app fills the best video's frame
/// (`fill`) with a fresh `Hop`, which marks its video and, from a subframe, posts the hop's token to its parent's
/// origin (`location.ancestorOrigins`) under the hop's random key. The parent's script takes it only from one of its
/// own iframes and relays it to the app (`Message.hop`) with the sender's origin; the app accepts the hop once, from
/// the expected child's origin, and has that frame mark the iframe the token came from and post a fresh hop on up
/// (`pass`), to the top frame. Unfilling (`unfill`), run in every frame that marked, removes the marks.
///
/// What the page can see while filled: one attribute with a random name, made in each marking frame per fill, on each
/// marked element; one constructed stylesheet styling it, in `document.adoptedStyleSheets` (WebKit lists it in
/// `document.styleSheets` too, but it is no DOM node, so no mutation shows it); and, per hop, one message to the parent
/// of a random key and token. Nothing names Lodge. Nothing the page holds is reported: only flags, the video's size and its area.
///
/// Limits: a video in a shadow root, or one the page hides under an ancestor's stacking context; a parent whose origin
/// is opaque (a sandboxed frame) gets the hop with target origin `*`.
public enum VideoPopOutScript {
    /// `WKContentWorld.world(name:)`: the page cannot see the script's state nor post to its handler.
    public static let worldName = "lodge.video"
    public static let handlerName = "lodgeVideo"
    /// The script's controls on its world's `window`, which the page's world does not see.
    static let controlName = "lodgeVideoPopOut"
    /// A smaller video (a thumbnail, a preview) is never the page's video.
    public static let minimumSide = 120
    /// A video's reported width or height is at most this.
    public static let maximumSide = 100_000

    /// A tab's video: the best of its frames' reports, or none.
    public struct State: Equatable, Sendable {
        public var hasVideo: Bool
        public var isPlaying: Bool
        public var isMuted: Bool
        /// The video's own size in pixels, 0 while unknown.
        public var width: Int
        public var height: Int

        public init(hasVideo: Bool, isPlaying: Bool, isMuted: Bool, width: Int, height: Int) {
            self.hasVideo = hasVideo
            self.isPlaying = isPlaying
            self.isMuted = isMuted
            self.width = width
            self.height = height
        }

        public static let none = State(hasVideo: false, isPlaying: false, isMuted: false, width: 0, height: 0)
    }

    /// One frame's document's best video, with its on-screen area in that frame.
    public struct Report: Equatable, Sendable {
        public var document: String
        public var state: State
        public var area: Double

        public init(document: String, state: State, area: Double) {
            self.document = document
            self.state = state
            self.area = area
        }
    }

    public enum Message: Equatable, Sendable {
        /// The document's best video now; sent once when the document loads, then on every change.
        case report(Report)
        /// `pagehide` of the document: its report no longer stands.
        case gone(document: String)
        /// While filling: one of the document's iframes, of `origin`, posted it `token`.
        case hop(document: String, token: String, origin: String)
    }

    /// Decodes `{doc, hasVideo, isPlaying, isMuted, width, height, area}`, `{doc, gone: true}` or
    /// `{doc, hop, from}`; anything else is nil. A size above `maximumSide` reads as `maximumSide`.
    public static func message(from body: Any) -> Message? {
        guard let body = body as? [String: Any], let document = body["doc"] as? String,
            (1...64).contains(document.count)
        else { return nil }
        if body.count == 2, body["gone"] as? Bool == true { return .gone(document: document) }
        if body.count == 3, let token = body["hop"] as? String, Hop.isToken(token), let origin = body["from"] as? String,
            (1...2048).contains(origin.utf8.count)
        {
            return .hop(document: document, token: token, origin: origin)
        }
        guard body.count == 7,
            let hasVideo = body["hasVideo"] as? Bool, let isPlaying = body["isPlaying"] as? Bool,
            let isMuted = body["isMuted"] as? Bool,
            let width = (body["width"] as? NSNumber)?.doubleValue, let height = (body["height"] as? NSNumber)?.doubleValue,
            let area = (body["area"] as? NSNumber)?.doubleValue,
            width >= 0, height >= 0, area >= 0, area.isFinite
        else { return nil }
        let state = State(
            hasVideo: hasVideo, isPlaying: isPlaying, isMuted: isMuted, width: Int(min(width, Double(maximumSide))),
            height: Int(min(height, Double(maximumSide))))
        return .report(Report(document: document, state: state, area: area))
    }

    /// Playing with sound first, then playing muted, then paused; a larger one first within each.
    public static func rank(_ state: State, area: Double) -> Double {
        (state.isPlaying ? (state.isMuted ? 1 : 2) : 0) * 1e12 + area
    }

    /// The frame report holding the tab's video: the first by `rank` among those with one; nil when none has.
    public static func best(_ reports: some Sequence<Report>) -> Report? {
        reports.filter(\.state.hasVideo).max {
            (rank($0.state, area: $0.area), $1.document) < (rank($1.state, area: $1.area), $0.document)
        }
    }

    /// A tab's frames' reports of a video, by document, each with the frame it came from. A report without a video,
    /// or `gone`, removes its document's; past `capacity` documents, the lowest by `rank`, then the least recently
    /// reported, goes, so a page that keeps making frames holds at most `capacity`.
    public struct Reports<Frame> {
        public static var capacity: Int { 32 }

        private var entries: [String: (report: Report, frame: Frame, order: Int)] = [:]
        private var clock = 0

        public init() {}

        public var count: Int { entries.count }
        public var isEmpty: Bool { entries.isEmpty }

        /// Takes in a frame's report or `gone`; a `hop` changes nothing.
        public mutating func apply(_ message: Message, from frame: Frame) {
            switch message {
            case .report(let report) where report.state.hasVideo:
                clock += 1
                entries[report.document] = (report, frame, clock)
                guard entries.count > Self.capacity,
                    let lowest = entries.min(by: {
                        (rank($0.value.report.state, area: $0.value.report.area), $0.value.order)
                            < (rank($1.value.report.state, area: $1.value.report.area), $1.value.order)
                    })
                else { return }
                entries[lowest.key] = nil
            case .report(let report): entries[report.document] = nil
            case .gone(let document): entries[document] = nil
            case .hop: break
            }
        }

        /// Drops every report whose frame `isGone` says no longer exists.
        public mutating func removeAll(where isGone: (Frame) -> Bool) {
            entries = entries.filter { !isGone($0.value.frame) }
        }

        /// The tab's video and its frame: the report first by `rank` (`VideoPopOutScript.best`).
        public var best: (report: Report, frame: Frame)? {
            VideoPopOutScript.best(entries.values.map(\.report)).flatMap { best in
                entries[best.document].map { ($0.report, $0.frame) }
            }
        }

        /// Whether a frame of the tab reported `document` (tests).
        func contains(_ document: String) -> Bool { entries[document] != nil }
    }

    /// One step of filling: the child frame posts `token` under `key` to its parent, whose script relays it with the
    /// child's origin. Made fresh for each frame on the way up; `accepts` it once, from the expected child only.
    public struct Hop: Equatable, Sendable {
        /// 12 random lower-case letters.
        public let key: String
        /// 32 random lower-case hexadecimal digits.
        public let token: String
        /// The origin of the frame that posts it, as `MessageEvent.origin` spells it.
        public let childOrigin: String

        public init(childOrigin: String) {
            var random = SystemRandomNumberGenerator()
            key = String((0..<12).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122, using: &random))) })
            token = (0..<32).map { _ in String(Int.random(in: 0..<16, using: &random), radix: 16) }.joined()
            self.childOrigin = childOrigin
        }

        /// The relayed `token` is this hop's and came from the child's origin.
        public func accepts(token: String, from origin: String) -> Bool {
            token == self.token && origin == childOrigin
        }

        static func isToken(_ text: String) -> Bool {
            text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        /// A frame's origin as `MessageEvent.origin` spells it, from its security origin's parts (`port` 0: the
        /// scheme's default); an opaque one (a sandboxed frame's: no scheme, or no host outside `file`) is "null".
        public static func origin(protocol scheme: String, host: String, port: Int) -> String {
            if scheme.isEmpty || (host.isEmpty && scheme != "file") { return "null" }
            let host = host.contains(":") ? "[\(host)]" : host
            return "\(scheme)://\(host)\(port == 0 ? "" : ":\(port)")"
        }
    }

    /// Function bodies for `callAsyncJavaScript` in `worldName`, in one frame. `fill` (arguments `key`, `nonce`: a
    /// `Hop`'s key and token) marks the frame's video and, from a subframe, posts the hop to its parent; true when it
    /// had one. `pass` (arguments `token`, the relayed one, then the next hop's `key` and `nonce`) marks the iframe
    /// that posted `token` and posts the next hop on up, once; true when it marked one. `unfill` puts the frame back.
    public static let fill = "return window.\(controlName) ? window.\(controlName).fill(key, nonce) : false;"
    public static let pass = "return window.\(controlName) ? window.\(controlName).pass(token, key, nonce) : false;"
    public static let unfill = "if (window.\(controlName)) { window.\(controlName).unfill(); } return true;"
    /// Plays or pauses the video this frame marked while filling (the mini player's click); true when it had one.
    public static let togglePlayback = "return window.\(controlName) ? window.\(controlName).toggle() : false;"

    /// What the element marked by `selector` and its ancestors get while filled, so the panel shows that element
    /// alone, whole. It is fixed over the viewport, its video contained, nothing of its own clipping or moving it. Its
    /// ancestors lose everything that would make one of them its containing block or clip it, or trap it in a stacking
    /// context: transforms (the individual `translate`, `rotate` and `scale` too), filters, containment, container
    /// queries, `content-visibility`, clip paths, masks, opacity, isolation, blending and overflow. Every other
    /// element is hidden (a page's own `visibility: visible` included) and the root is black and stops scrolling.
    static func css(_ selector: String) -> String {
        """
        \(selector){position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;\
        max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;\
        margin:0!important;padding:0!important;border:0!important;transform:none!important;translate:none!important;\
        rotate:none!important;scale:none!important;clip-path:none!important;mask:none!important;filter:none!important;\
        z-index:2147483647!important;object-fit:contain!important;object-position:50% 50%!important;\
        background:#000!important;visibility:visible!important;opacity:1!important}\
        :has(\(selector)){transform:none!important;translate:none!important;rotate:none!important;\
        scale:none!important;filter:none!important;backdrop-filter:none!important;contain:none!important;\
        container-type:normal!important;content-visibility:visible!important;perspective:none!important;\
        will-change:auto!important;clip-path:none!important;mask:none!important;opacity:1!important;\
        isolation:auto!important;mix-blend-mode:normal!important;overflow:visible!important;\
        z-index:2147483647!important}\
        html:has(\(selector)) *:not(\(selector)){visibility:hidden!important}\
        html:has(\(selector)),html:has(\(selector)) body{overflow:hidden!important;background:#000!important}
        """
    }

    /// Injected at document end, `forMainFrameOnly: false`. Reports are coalesced (100 ms) and sent only on change,
    /// the first at load; `pagehide` sends `gone` at once, `pageshow` from the back/forward cache reports again.
    public static let source = """
        (() => {
          const handlers = window.webkit && window.webkit.messageHandlers;
          const handler = handlers && handlers.\(handlerName);
          if (!handler) { return; }
          const isTop = window.top === window;
          const minArea = \(minimumSide * minimumSide);
          const maxSide = \(maximumSide);
          const isKey = (k) => typeof k === 'string' && /^[a-z]{12}$/.test(k);
          const isToken = (t) => typeof t === 'string' && /^[0-9a-f]{32}$/.test(t);
          const css = \(jsString(css("\u{1}")));
          const doc = (typeof crypto !== 'undefined' && crypto.randomUUID)
            ? crypto.randomUUID()
            : Math.random().toString(36).slice(2) + Date.now().toString(36);
          const none = { hasVideo: false, isPlaying: false, isMuted: false, width: 0, height: 0, area: 0 };
          const post = (message) => { try { handler.postMessage(message); } catch (_) {} };
          let last = '';
          let waiting = false;
          // While filled: this fill's random attribute, its stylesheet and the elements it marked.
          let filled = null;
          // Tokens a child iframe posted, until the app passes them on or unfills.
          const pending = new Map();
          const letters = (n) => {
            const bytes = new Uint8Array(n);
            crypto.getRandomValues(bytes);
            return Array.from(bytes, (b) => String.fromCharCode(97 + (b % 26))).join('');
          };
          const frameOf = (win) => {
            for (const el of document.querySelectorAll('iframe, frame')) { if (el.contentWindow === win) { return el; } }
            return null;
          };
          const rank = (c) => (c.isPlaying ? (c.isMuted ? 1 : 2) : 0) * 1e12 + c.area;
          const best = () => {
            let found = null;
            for (const video of document.querySelectorAll('video')) {
              const box = video.getBoundingClientRect();
              const area = box.width * box.height;
              if (!(area >= minArea)) { continue; }
              const c = { hasVideo: true, isPlaying: !video.paused && !video.ended,
                isMuted: video.muted || video.volume === 0, width: Math.min(maxSide, video.videoWidth | 0),
                height: Math.min(maxSide, video.videoHeight | 0), area: area, video: video };
              if (!found || rank(c) > rank(found)) { found = c; }
            }
            return found;
          };
          const report = () => {
            waiting = false;
            const c = best() || none;
            const message = { doc: doc, hasVideo: c.hasVideo, isPlaying: c.isPlaying, isMuted: c.isMuted,
              width: Math.max(0, c.width), height: Math.max(0, c.height), area: c.area };
            const text = JSON.stringify(message);
            if (text === last) { return; }
            last = text;
            post(message);
          };
          const schedule = () => { if (!waiting) { waiting = true; setTimeout(report, 100); } };
          // The parent's origin, or '' when it is opaque or unknown.
          const parentOrigin = () => {
            try {
              const o = location.ancestorOrigins;
              return o && o.length && o[0] && o[0] !== 'null' ? String(o[0]) : '';
            } catch (_) { return ''; }
          };
          // Marks `el` with this fill's attribute, styled by a constructed sheet, and posts the next hop to the
          // parent: the one message sent to another frame, only while filling.
          const mark = (el, key, nonce) => {
            if (!filled) {
              const attr = 'data-' + letters(10);
              const sheet = new CSSStyleSheet();
              sheet.replaceSync(css.split('\\u0001').join('[' + attr + ']'));
              document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
              filled = { attr: attr, sheet: sheet, marked: [] };
            }
            el.setAttribute(filled.attr, '');
            filled.marked.push(el);
            if (!isTop && isKey(key) && isToken(nonce)) {
              try { window.parent.postMessage({ [key]: nonce }, parentOrigin() || '*'); } catch (_) {}
            }
            return true;
          };
          const fill = (key, nonce) => {
            const found = best();
            return found ? mark(found.video, key, nonce) : false;
          };
          const pass = (token, key, nonce) => {
            const el = pending.get(token);
            pending.delete(token);
            return el && el.isConnected ? mark(el, key, nonce) : false;
          };
          const toggle = () => {
            const el = filled && filled.marked.find((e) => e.localName === 'video');
            if (!el) { return false; }
            if (el.paused || el.ended) { el.play().catch(() => {}); } else { el.pause(); }
            return true;
          };
          const unfill = () => {
            pending.clear();
            if (!filled) { return; }
            for (const el of filled.marked) { el.removeAttribute(filled.attr); }
            const sheet = filled.sheet;
            document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== sheet);
            filled = null;
          };
          window.addEventListener('message', (e) => {
            const data = e.data;
            if (!data || typeof data !== 'object') { return; }
            const keys = Object.keys(data);
            if (keys.length !== 1 || !isKey(keys[0]) || !isToken(data[keys[0]])) { return; }
            const el = e.source && frameOf(e.source);
            if (!el) { return; }
            if (pending.size >= 8) { pending.delete(pending.keys().next().value); }
            pending.set(data[keys[0]], el);
            post({ doc: doc, hop: data[keys[0]], from: String(e.origin) });
          }, true);
          const options = { capture: true, passive: true };
          for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange', 'loadedmetadata', 'emptied', 'resize']) {
            document.addEventListener(type, schedule, options);
          }
          window.addEventListener('pagehide', () => { last = ''; post({ doc: doc, gone: true }); }, options);
          window.addEventListener('pageshow', (e) => { if (e.persisted) { schedule(); } }, options);
          window.\(controlName) = { fill: fill, pass: pass, unfill: unfill, toggle: toggle };
          schedule();
        })();
        """

    /// `text` as a JavaScript string literal.
    private static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
