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
/// Controls (the mini player's, pulled by the app, never pushed): the frame that marked the video plays or pauses it,
/// seeks it within its `seekable` ranges, flips its `muted`, and, in YouTube's top frame only, clicks the page's own
/// next button; each call answers with the video's `Playback` (time, duration, seekable range, paused, muted, whether
/// a next button shows, size). If the page swaps the video element while filled, the frame marks the new one in its
/// place (the best video under the old one's parent while that parent is connected, else in the document), watching for that through `emptied` /
/// `loadstart` and a `MutationObserver` on that parent, disconnected on unfill. What the page sees of controls is only
/// what a user's own click on its player would do: `play()`, `pause()`, a `currentTime` or `muted` change, a click on
/// its next button; and the fill's attribute moving to the new video. A page could still tell: that click is
/// untrusted (`isTrusted` false), and the seek buttons land on exact ±5 s steps.
///
/// Picture in Picture (iOS, where WKWebView has no mini player): the app asks the best video's frame to `present` its
/// video in a presentation mode, and every frame reports its videos' mode changes (`Message.presentation`) on WebKit's
/// `webkitpresentationmodechanged`: entering PiP at once, leaving it 250 ms later, so a pause that closing PiP makes
/// has landed by then. The page sees only
/// what a user's tap on its video's own PiP button would do.
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

    /// A video's `webkitPresentationMode`.
    public enum PresentationMode: String, Sendable {
        case inline
        case pictureInPicture = "picture-in-picture"
        case fullscreen
    }

    public enum Message: Equatable, Sendable {
        /// The document's best video now; sent once when the document loads, then on every change.
        case report(Report)
        /// `pagehide` of the document: its report no longer stands.
        case gone(document: String)
        /// While filling: one of the document's iframes, of `origin`, posted it `token`.
        case hop(document: String, token: String, origin: String)
        /// One of the document's videos changed its presentation mode to `mode`; `isPaused` as it was then, or, for a
        /// mode leaving PiP, 250 ms later.
        case presentation(document: String, mode: PresentationMode, isPaused: Bool)
    }

    /// Decodes `{doc, hasVideo, isPlaying, isMuted, width, height, area}`, `{doc, gone: true}`, `{doc, hop, from}`
    /// or `{doc, mode, paused}` (`mode` a `PresentationMode` raw value); anything else is nil. A size above `maximumSide` reads as `maximumSide`.
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
        if body.count == 3, let mode = (body["mode"] as? String).flatMap(PresentationMode.init(rawValue:)),
            let paused = body["paused"] as? NSNumber, CFGetTypeID(paused) == CFBooleanGetTypeID()
        {
            return .presentation(document: document, mode: mode, isPaused: paused.boolValue)
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

        /// Takes in a frame's report or `gone`; a `hop` or a `presentation` changes nothing.
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
            case .hop, .presentation: break
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
    /// The mini player's controls, function bodies for `callAsyncJavaScript` in the frame that marked the video. Each
    /// acts on the filled video (`current()`, re-picked when the page swapped it) and returns its `playback()`
    /// (`Playback.from` decodes it), or null when the frame has none. `togglePlayback` plays or pauses; `seek`
    /// (argument `by`, seconds, |by| ≤ 3600) and `seekTo` (argument `time`) move within `video.seekable`, doing
    /// nothing when it is empty; `toggleMute` flips `muted` only; `next` clicks YouTube's own next button, only in the
    /// top frame of `youtube.com` or a subdomain, and only while that button shows and is enabled.
    public static let playback = "return window.\(controlName) ? window.\(controlName).playback() : null;"
    public static let togglePlayback = "return window.\(controlName) ? window.\(controlName).toggle() : null;"
    public static let seek = "return window.\(controlName) ? window.\(controlName).seek(by) : null;"
    public static let seekTo = "return window.\(controlName) ? window.\(controlName).seekTo(time) : null;"
    public static let toggleMute = "return window.\(controlName) ? window.\(controlName).toggleMute() : null;"
    public static let next = "return window.\(controlName) ? window.\(controlName).next() : null;"

    /// Function body for `callAsyncJavaScript` in `worldName`, in one frame, argument `mode` (a `PresentationMode` raw
    /// value): the frame's own best video (the one it reports) gets `webkitSetPresentationMode(mode)` when it
    /// `webkitSupportsPresentationMode(mode)`; true when it asked, false when the frame has none or cannot.
    public static let present = "return window.\(controlName) ? window.\(controlName).present(mode) : false;"

    /// The filled video's playback, as a control call or `playback` returns it.
    public struct Playback: Equatable, Sendable {
        /// Seconds, ≥ 0, finite.
        public var time: Double
        /// Nil when unknown or not finite (live).
        public var duration: Double?
        /// The first start … last end of `video.seekable`; nil when empty.
        public var seekable: ClosedRange<Double>?
        public var isPaused: Bool
        public var isMuted: Bool
        public var hasNext: Bool
        /// The video's size, 0 while unknown, at most `maximumSide`.
        public var width: Int
        public var height: Int

        public var canSeek: Bool { duration != nil && seekable != nil }

        /// A time, duration or seekable bound above this (about 115 days) reads as this, so a page's absurd one
        /// (an MSE duration of 1e300) still converts to a whole number of seconds.
        public static let maximumSeconds: Double = 10_000_000

        public init(
            time: Double, duration: Double?, seekable: ClosedRange<Double>?, isPaused: Bool, isMuted: Bool,
            hasNext: Bool, width: Int, height: Int
        ) {
            self.time = time
            self.duration = duration
            self.seekable = seekable
            self.isPaused = isPaused
            self.isMuted = isMuted
            self.hasNext = hasNext
            self.width = width
            self.height = height
        }

        /// Decodes `{time, duration, start, end, paused, muted, next, width, height}` exactly (9 keys); numbers
        /// finite (duration/start/end may be -1 = none), time clamped to ≥ 0; start > end → seekable nil; else nil.
        /// A size above `maximumSide` reads as `maximumSide`; a time above `maximumSeconds` as `maximumSeconds`.
        public static func from(_ result: Any?) -> Playback? {
            guard let body = result as? [String: Any], body.count == 9,
                let time = number(body["time"]), let duration = number(body["duration"]),
                let start = number(body["start"]), let end = number(body["end"]),
                let width = number(body["width"]), let height = number(body["height"]),
                let paused = body["paused"] as? Bool, let muted = body["muted"] as? Bool,
                let next = body["next"] as? Bool,
                [duration, start, end].allSatisfy({ $0 >= 0 || $0 == -1 }), width >= 0, height >= 0
            else { return nil }
            return Playback(
                time: clamped(time), duration: duration == -1 ? nil : clamped(duration),
                seekable: start == -1 || end == -1 || start > end ? nil : clamped(start)...clamped(end),
                isPaused: paused, isMuted: muted, hasNext: next, width: Int(min(width, Double(maximumSide))),
                height: Int(min(height, Double(maximumSide))))
        }

        private static func clamped(_ seconds: Double) -> Double { min(max(0, seconds), maximumSeconds) }

        private static func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let number = value.doubleValue
            return number.isFinite ? number : nil
        }
    }

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
    /// the first at load; `pagehide` sends `gone` at once, `pageshow` from the back/forward cache reports again. A
    /// video's `webkitpresentationmodechanged` sends its mode and paused: at once into PiP, 250 ms later out of it.
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
          // While filled: this fill's random attribute, its stylesheet, the elements it marked and, in the video's own
          // frame, the video, its parent when marked and the observer of that parent's subtree.
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
          const best = (root) => {
            let found = null;
            for (const video of (root || document).querySelectorAll('video')) {
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
              filled = { attr: attr, sheet: sheet, marked: [], video: null, container: null, observer: null };
            }
            el.setAttribute(filled.attr, '');
            filled.marked.push(el);
            if (el.localName === 'video' && !filled.video) {
              filled.video = el;
              filled.container = el.parentElement || null;
              if (filled.container && typeof MutationObserver === 'function') {
                filled.observer = new MutationObserver(() => { current(); });
                filled.observer.observe(filled.container, { childList: true, subtree: true });
              }
            }
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
          // The filled video; when the page replaced it, the best one in its old parent while that is connected (none
          // there yet: null, until the next mutation or event), else in the document, marked in its place.
          const current = () => {
            if (!filled || !filled.video) { return null; }
            const old = filled.video;
            if (old.isConnected) { return old; }
            const container = filled.container;
            const found = container && container.isConnected ? best(container) : best();
            if (!found) { return null; }
            const video = found.video;
            old.removeAttribute(filled.attr);
            video.setAttribute(filled.attr, '');
            filled.marked[filled.marked.indexOf(old)] = video;
            filled.video = video;
            return video;
          };
          const finite = (n) => typeof n === 'number' && isFinite(n);
          const range = (v) => {
            const s = v.seekable;
            return s && s.length ? [s.start(0), s.end(s.length - 1)] : null;
          };
          // YouTube's own next button, in its top frame, while it shows and is enabled.
          const nextButton = () => {
            if (!isTop) { return null; }
            let host = '';
            try { host = String(location.hostname || ''); } catch (_) { return null; }
            if (host !== 'youtube.com' && !host.endsWith('.youtube.com')) { return null; }
            const b = document.querySelector('.ytp-next-button');
            return b && b.isConnected && b.getClientRects().length > 0 && b.getAttribute('aria-disabled') !== 'true'
              ? b : null;
          };
          const playback = () => {
            const v = current();
            if (!v) { return null; }
            const r = range(v);
            const ok = r && finite(r[0]) && finite(r[1]);
            return { time: finite(v.currentTime) ? Math.max(0, v.currentTime) : 0,
              duration: finite(v.duration) && v.duration >= 0 ? v.duration : -1,
              start: ok && r[0] >= 0 ? r[0] : -1, end: ok && r[1] >= 0 ? r[1] : -1,
              paused: !!(v.paused || v.ended), muted: !!v.muted, next: !!nextButton(),
              width: Math.min(maxSide, v.videoWidth | 0), height: Math.min(maxSide, v.videoHeight | 0) };
          };
          const seekTo = (t) => {
            const v = current();
            if (!v) { return null; }
            const r = range(v);
            if (r && finite(t)) { v.currentTime = Math.min(r[1], Math.max(r[0], t)); }
            return playback();
          };
          const seek = (by) => {
            const v = current();
            if (!v) { return null; }
            return finite(by) && Math.abs(by) <= 3600 ? seekTo(v.currentTime + by) : playback();
          };
          const toggle = () => {
            const v = current();
            if (!v) { return null; }
            if (v.paused || v.ended) { v.play().catch(() => {}); } else { v.pause(); }
            return playback();
          };
          const toggleMute = () => {
            const v = current();
            if (!v) { return null; }
            v.muted = !v.muted;
            return playback();
          };
          const next = () => {
            if (!current()) { return null; }
            const b = nextButton();
            if (b) { b.click(); }
            return playback();
          };
          const modes = ['inline', 'picture-in-picture', 'fullscreen'];
          const present = (mode) => {
            if (modes.indexOf(mode) < 0) { return false; }
            const found = best();
            const v = found && found.video;
            if (!v || typeof v.webkitSupportsPresentationMode !== 'function'
              || typeof v.webkitSetPresentationMode !== 'function' || !v.webkitSupportsPresentationMode(mode)) {
              return false;
            }
            v.webkitSetPresentationMode(mode);
            return true;
          };
          const presented = (e) => {
            const v = e && e.target;
            if (!v || v.localName !== 'video') { return; }
            const send = () => {
              const mode = v.webkitPresentationMode;
              if (modes.indexOf(mode) < 0) { return; }
              post({ doc: doc, mode: mode, paused: !!(v.paused || v.ended) });
            };
            if (v.webkitPresentationMode === 'picture-in-picture') { send(); } else { setTimeout(send, 250); }
          };
          const unfill = () => {
            pending.clear();
            if (!filled) { return; }
            if (filled.observer) { filled.observer.disconnect(); }
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
          for (const type of ['emptied', 'loadstart']) {
            document.addEventListener(type, () => { if (filled) { current(); } }, options);
          }
          document.addEventListener('webkitpresentationmodechanged', presented, options);
          window.addEventListener('pagehide', () => { last = ''; post({ doc: doc, gone: true }); }, options);
          window.addEventListener('pageshow', (e) => { if (e.persisted) { schedule(); } }, options);
          window.\(controlName) = { fill: fill, pass: pass, unfill: unfill, toggle: toggle, playback: playback,
            seek: seek, seekTo: seekTo, toggleMute: toggleMute, next: next, present: present };
          schedule();
        })();
        """

    /// `text` as a JavaScript string literal.
    private static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
