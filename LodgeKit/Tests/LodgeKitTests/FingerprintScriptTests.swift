import Foundation
import JavaScriptCore
import Testing

@testable import LodgeKit

@Suite struct FingerprintScriptTests {
    private static let seed = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"

    /// A context that records the first exception; `run` fails the test on one.
    private final class Page {
        let context = JSContext()!
        private(set) var exception: String?

        init() {
            context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
        }

        @discardableResult
        func run(_ script: String) -> JSValue {
            let value = context.evaluateScript(script)!
            #expect(exception == nil, "\(exception ?? "")")
            return value
        }
    }

    /// A stand-in page world: a document that records dispatched apis; canvases and offscreen canvases whose 2D
    /// contexts keep a surface without premultiplying (each 16th pixel half transparent, each 8th of the rest fully
    /// transparent) and whose encoders spell out the pixels; audio buffers, an offline context that renders one, a
    /// decoder, an analyser; an iframe and `open` that hand out blank realms with their own 2D context; a top frame at
    /// `www.example.com`, a `URL` that parses a host and a `crypto` that counts its calls.
    private static let fakeWorld = """
        var events = [];
        function EventTarget() {}
        EventTarget.prototype.dispatchEvent = function dispatchEvent(e) {
          events.push((this === document ? '' : 'elsewhere:') + e.type + ':' + e.detail);
          return true;
        };
        function CustomEvent(type, init) { this.type = type; this.detail = init.detail; }
        function DOMException(message, name) { this.message = message; this.name = name; }
        function Document() {}
        Document.prototype = Object.create(EventTarget.prototype);
        Document.prototype.createElement = function createElement(tag) { return new HTMLCanvasElement(); };
        var document = new Document();
        var location = { protocol: 'https:', hostname: 'www.example.com', ancestorOrigins: [] };
        var parent = globalThis;
        function URL(s) {
          const m = /^[a-z]+:\\/\\/(\\[[^\\]]*\\]|[^/:]*)/.exec(s);
          if (!m) { throw new TypeError('Invalid URL'); }
          this.hostname = m[1];
        }
        var randomCalls = 0;
        var crypto = { getRandomValues(a) {
          randomCalls++;
          for (let i = 0; i < a.length; i++) { a[i] = Math.floor(Math.random() * 256); }
          return a;
        } };
        var spaces = [];
        var noContext = false;

        function alphaAt(p) { return p % 16 === 15 ? 128 : (p % 8 === 7 ? 0 : 255); }
        function surface(width, height) {
          const px = new Uint8ClampedArray(width * height * 4);
          for (let i = 0; i < px.length; i++) { px[i] = (i % 4 === 3) ? alphaAt(i >> 2) : (i * 37) % 256; }
          return { width: width, height: height, px: px };
        }
        function makeContext2D(proto) {
          proto.getImageData = function getImageData(sx, sy, sw, sh) {
            if (arguments[4]) { spaces.push('get:' + arguments[4].colorSpace); }
            const data = new Uint8ClampedArray(sw * sh * 4);
            for (let y = 0; y < sh; y++) for (let x = 0; x < sw; x++) for (let c = 0; c < 4; c++)
              data[(y * sw + x) * 4 + c] = this.s.px[((sy + y) * this.s.width + sx + x) * 4 + c];
            return { data: data, width: sw, height: sh };
          };
          proto.putImageData = function putImageData(image, dx, dy) {
            for (let y = 0; y < image.height; y++) for (let x = 0; x < image.width; x++) for (let c = 0; c < 4; c++)
              this.s.px[((dy + y) * this.s.width + dx + x) * 4 + c] = image.data[(y * image.width + x) * 4 + c];
          };
          proto.drawImage = function drawImage(source, dx, dy) {
            for (let i = 0; i < this.s.px.length; i++) { this.s.px[i] = source.ctx.s.px[i]; }
          };
          proto.getContextAttributes = function getContextAttributes() { return { colorSpace: this.space }; };
        }
        function canvasKind(Canvas, Context) {
          Canvas.prototype.getContext = function getContext(type, options) {
            if (noContext && !this.ctx) { return null; }
            if (!this.ctx) {
              this.ctx = new Context();
              this.ctx.s = surface(this.width, this.height);
              this.ctx.space = (options && options.colorSpace) || 'srgb';
              spaces.push('make:' + this.ctx.space);
            }
            return this.ctx;
          };
        }
        function encode(c) { return 'png:' + (c.ctx ? Array.from(c.ctx.s.px).join('.') : ''); }
        function CanvasRenderingContext2D() { this.s = surface(16, 8); }
        makeContext2D(CanvasRenderingContext2D.prototype);
        function HTMLCanvasElement() { this.width = 16; this.height = 8; this.ctx = null; }
        canvasKind(HTMLCanvasElement, CanvasRenderingContext2D);
        HTMLCanvasElement.prototype.toDataURL = function toDataURL(type, quality) { return encode(this); };
        HTMLCanvasElement.prototype.toBlob = function toBlob(callback, type, quality) { callback({ data: encode(this) }); };
        function OffscreenCanvasRenderingContext2D() { this.s = surface(16, 8); }
        makeContext2D(OffscreenCanvasRenderingContext2D.prototype);
        function OffscreenCanvas(width, height) { this.width = width; this.height = height; this.ctx = null; }
        canvasKind(OffscreenCanvas, OffscreenCanvasRenderingContext2D);
        OffscreenCanvas.prototype.convertToBlob = function convertToBlob(options) {
          return Promise.resolve({ data: encode(this) });
        };

        function AudioBuffer(channels, length) {
          this.numberOfChannels = channels;
          this.length = length;
          this.data = [];
          for (let c = 0; c < channels; c++) {
            const d = new Float32Array(length);
            for (let i = 0; i < length; i++) d[i] = Math.sin(i + c) * 0.5;
            this.data.push(d);
          }
        }
        AudioBuffer.prototype.getChannelData = function getChannelData(c) { return this.data[c]; };
        AudioBuffer.prototype.copyFromChannel = function copyFromChannel(dest, c, start) {
          const s = start || 0;
          const n = Math.min(dest.length, this.length - s);
          for (let i = 0; i < n; i++) dest[i] = this.data[c][s + i];
        };
        function BaseAudioContext() {}
        BaseAudioContext.prototype.decodeAudioData = function decodeAudioData(data, success, failure) {
          const b = new AudioBuffer(1, 32);
          if (success) { success(b); }
          return Promise.resolve(b);
        };
        function OfflineAudioContext() {}
        OfflineAudioContext.prototype = Object.create(BaseAudioContext.prototype);
        OfflineAudioContext.prototype.startRendering = function startRendering() {
          return Promise.resolve(new AudioBuffer(2, 64));
        };
        function AnalyserNode() { this.frequencyBinCount = 8; this.fftSize = 16; }
        AnalyserNode.prototype.getFloatFrequencyData = function getFloatFrequencyData(a) {
          for (let i = 0; i < Math.min(a.length, 8); i++) a[i] = -30.25 - i;
        };
        AnalyserNode.prototype.getByteFrequencyData = function getByteFrequencyData(a) {
          for (let i = 0; i < Math.min(a.length, 8); i++) a[i] = 100 + i * 2;
        };

        function makeRealm() {
          function Context() { this.s = surface(4, 4); }
          makeContext2D(Context.prototype);
          return { CanvasRenderingContext2D: Context, location: { protocol: 'about:' }, parent: globalThis,
            document: new Document() };
        }
        var frame = makeRealm();
        function HTMLIFrameElement() {}
        Object.defineProperty(HTMLIFrameElement.prototype, 'contentWindow',
          { get: function () { return frame; }, configurable: true, enumerable: true });
        Object.defineProperty(HTMLIFrameElement.prototype, 'contentDocument',
          { get: function () { return frame.document; }, configurable: true, enumerable: true });
        var popup = makeRealm();
        function open(url) { return popup; }
        """

    private static let site = "example.com"

    /// The fake world, `setup` run in it, then the patch seeded with `seed` for `site`.
    private func page(seed: String = seed, site: String = site, exactHost: Bool = false, setup: String = "") -> Page {
        let page = Page()
        page.run(Self.fakeWorld)
        page.run(setup)
        page.run(FingerprintScript.pageSource(seed: seed, site: site, exactHost: exactHost))
        return page
    }

    private func helpers(_ page: Page, seed: String = seed) {
        page.run("var noise = \(FingerprintScript.noiseSource(seed: seed));")
    }

    // MARK: Messages and source

    @Test func readsEachApiFromTheRelay() {
        for api in [FingerprintAPI.canvas, .webgl, .audio] {
            #expect(FingerprintScript.api(from: ["api": api.rawValue]) == api)
        }
    }

    @Test func rejectsAnythingElse() {
        let bodies: [Any] = [
            ["api": "font"], ["api": "Canvas"], ["api": 1], ["kind": "canvas"], ["api": "canvas", "doc": "a"],
            "canvas", 3, [String: Any](),
        ]
        for body in bodies { #expect(FingerprintScript.api(from: body) == nil, "\(body)") }
    }

    @Test func namesFollowTheDecision() {
        #expect(FingerprintScript.worldName == "lodge.fingerprint")
        #expect(FingerprintScript.handlerName == "lodgeFingerprint")
        #expect(FingerprintScript.eventName == "lodgefingerprintread")
    }

    /// A stand-in isolated world for the relay: its handler records posts, `window` and `document` their listeners.
    private func relayPage() -> Page {
        let page = Page()
        page.run("""
            var posted = [];
            var listeners = [];
            var windowListeners = [];
            var window = { webkit: { messageHandlers: { lodgeFingerprint: {
              postMessage: (m) => posted.push(JSON.stringify(m)) } } },
              addEventListener: (type, f, options) => windowListeners.push([type, f, options]) };
            var document = { addEventListener: (type, f, options) => listeners.push([type, f, options]) };
            """)
        page.run(FingerprintScript.relaySource)
        return page
    }

    @Test func relayReportsWhatTheDocumentReadAgainWhenRestoredFromTheCache() {
        let page = relayPage()
        let result = page.run("""
            const listen = listeners[0][1];
            const [type, show] = windowListeners[0];
            listen({ detail: 'canvas' });
            listen({ detail: 'audio' });
            show({ persisted: false });
            const before = posted.length;
            show({ persisted: true });
            listen({ detail: 'canvas' });
            listen({ detail: 'webgl' });
            [type, before, posted.join('|')].join();
            """).toString()
        #expect(
            result
                == #"pageshow,2,{"api":"canvas"}|{"api":"audio"}|{"api":"canvas"}|{"api":"audio"}|{"api":"webgl"}"#)
    }

    @Test func relayPostsAStringDetailOncePerApi() {
        let page = relayPage()
        let result = page.run("""
            const [type, listen, options] = listeners[0];
            for (const detail of ['canvas', { api: 'webgl' }, null, 'font', 'canvas', 'audio']) { listen({ detail: detail }); }
            [listeners.length, type, options.capture, posted.join('|')].join();
            """).toString()
        #expect(result == #"1,lodgefingerprintread,true,{"api":"canvas"}|{"api":"audio"}"#)
    }

    @Test func sourceCarriesTheSeedAsALiteral() {
        let source = FingerprintScript.pageSource(seed: Self.seed, site: Self.site, exactHost: false)
        #expect(source.contains("const SEED = '\(Self.seed)';"))
        let hostile = FingerprintScript.pageSource(seed: "ab';alert(1);'cd", site: Self.site, exactHost: false)
        #expect(hostile.contains("const SEED = 'abae1cd';"))
        #expect(!hostile.contains("alert"))
    }

    @Test func sourceCarriesTheSiteAsALiteral() {
        let source = FingerprintScript.pageSource(seed: Self.seed, site: "[::1]", exactHost: true)
        #expect(source.contains("const SITE = '[::1]';") && source.contains("const EXACT = true;"))
        let hostile = FingerprintScript.pageSource(
            seed: Self.seed, site: "Evil.com';alert(1);//\n\\'", exactHost: false)
        #expect(hostile.contains("const SITE = 'evil.comalert1';") && hostile.contains("const EXACT = false;"))
        #expect(!hostile.contains("alert(1)"))
        let page = page(site: "Evil.com';globalThis.broke=1;'")
        #expect(page.run("typeof broke").toString() == "undefined")
    }

    @Test func runsWhereNoCanvasWebGLOrAudioExists() {
        Page().run(FingerprintScript.pageSource(seed: Self.seed, site: Self.site, exactHost: false))
        let blank = Page()
        blank.run("var document = {}; var location = { protocol: 'about:' }; var parent = globalThis;")
        blank.run(FingerprintScript.pageSource(seed: Self.seed, site: Self.site, exactHost: false))
    }

    // MARK: Top site

    /// Every byte of a fresh 2D context's `getImageData`, read in the patched page.
    private static let canvasRead = "new CanvasRenderingContext2D().getImageData(0, 0, 16, 8).data.join()"

    /// The same read noised with `seed` by the helpers alone, or left as it is when `raw`.
    private func expectedRead(seed: String = seed, raw: Bool = false) -> String {
        let page = Page()
        page.run(Self.fakeWorld)
        helpers(page, seed: seed)
        return page.run("""
            const d = new CanvasRenderingContext2D().getImageData(0, 0, 16, 8).data;
            if (!\(raw)) { noise.pixels(d, 16, 0, 0); }
            d.join();
            """).toString()
    }

    @Test func aTopFrameOnTheSiteOrBelowItGetsTheSeed() {
        let seeded = expectedRead()
        for (site, host) in [
            ("example.com", "example.com"), ("example.com", "www.example.com"), ("Example.COM", "WWW.Example.com."),
            ("[::1]", "[::1]"), ("::1", "[::1]"), ("127.0.0.1", "127.0.0.1"),
        ] {
            let page = page(site: site, setup: "location.hostname = '\(host)';")
            #expect(page.run(Self.canvasRead).toString() == seeded, "\(site) at \(host)")
            #expect(page.run("randomCalls").toInt32() == 0, "\(site) at \(host)")
        }
    }

    @Test func aFrameFollowsItsTopFramesOriginNotItsOwnHost() {
        let seeded = expectedRead()
        let framed = page(setup: """
            parent = {};
            location.hostname = '';
            location.ancestorOrigins = ['https://evil.org', 'https://shop.example.com:8443'];
            """)
        #expect(framed.run(Self.canvasRead).toString() == seeded)
        let elsewhere = page(setup: """
            parent = {};
            location.ancestorOrigins = ['https://www.example.com', 'https://evil.org'];
            """)
        #expect(elsewhere.run(Self.canvasRead).toString() != seeded)
        let unknown = page(setup: "parent = {}; delete location.ancestorOrigins;")
        #expect(unknown.run(Self.canvasRead).toString() != seeded)
    }

    @Test func aWholeHostSiteMatchesOnlyThatHost() {
        let seeded = expectedRead()
        for (site, host, fits) in [
            ("github.io", "github.io", true), ("github.io", "foo.github.io", false),
            ("localhost", "localhost", true), ("localhost", "a.localhost", false),
            ("intranet", "wiki.intranet", false),
        ] {
            let page = page(site: site, exactHost: true, setup: "location.hostname = '\(host)';")
            #expect((page.run(Self.canvasRead).toString() == seeded) == fits, "\(site) at \(host)")
        }
        let framed = page(site: "localhost", exactHost: true, setup: """
            parent = {};
            location.ancestorOrigins = ['http://a.localhost:8080'];
            """)
        #expect(framed.run(Self.canvasRead).toString() != seeded)
    }

    @Test func aFrameUnderASandboxedTopReadsTopsHostElseAcceptsTheSite() {
        let seeded = expectedRead()
        let readable = page(setup: """
            parent = {};
            var top = { location: { hostname: 'www.example.com' } };
            location.ancestorOrigins = ['null'];
            """)
        #expect(readable.run(Self.canvasRead).toString() == seeded)
        let elsewhere = page(setup: """
            parent = {};
            var top = { location: { hostname: 'evil.org' } };
            location.ancestorOrigins = ['null'];
            """)
        #expect(elsewhere.run(Self.canvasRead).toString() != seeded)
        let unreadable = page(setup: """
            parent = {};
            var top = {};
            Object.defineProperty(top, 'location', { get() { throw new Error('SecurityError'); } });
            location.ancestorOrigins = ['https://evil.org', 'null'];
            """)
        #expect(unreadable.run(Self.canvasRead).toString() == seeded)
        #expect(unreadable.run("randomCalls").toInt32() == 0)
    }

    @Test func anotherTopSiteGetsAThrowawaySeedNeitherTheSeedNorRaw() {
        let seeded = expectedRead()
        let raw = expectedRead(raw: true)
        var reads: [String] = []
        for host in ["notexample.com", "example.com.evil.org", "", "example.co"] {
            let page = page(setup: "location.hostname = '\(host)';")
            let read = page.run(Self.canvasRead).toString() ?? ""
            #expect(read != seeded && read != raw, "\(host)")
            #expect(page.run("randomCalls").toInt32() == 1, "\(host)")
            reads.append(read)
        }
        #expect(Set(reads).count == reads.count)
        #expect(page(site: "';'").run(Self.canvasRead).toString() != seeded)
    }

    @Test func aRealmReachedFromAMismatchedPageSharesItsThrowawaySeed() {
        let lowBits = """
            const bits = (ctx) => {
              for (let i = 3; i < ctx.s.px.length; i += 4) { ctx.s.px[i] = 255; }
              return Array.from(ctx.getImageData(0, 0, 4, 4).data).filter((_, i) => i % 4 !== 3)
                .map((v) => v & 1).join('');
            };
            const w = new HTMLIFrameElement().contentWindow;
            [bits(new CanvasRenderingContext2D()), bits(new w.CanvasRenderingContext2D())];
            """
        let mismatched = page(setup: "location.hostname = 'evil.org';").run(lowBits).toArray() as? [String]
        #expect(mismatched?.count == 2 && mismatched?[0] == mismatched?[1])
        let matched = page().run(lowBits).toArray() as? [String]
        #expect(matched?.count == 2 && matched?[0] == matched?[1] && matched?[0] != mismatched?[0])
    }

    // MARK: Noise helpers

    @Test func noiseIsDeterministicPerSeed() {
        let script = """
            const px = new Uint8ClampedArray(64 * 4).map((_, i) => i % 4 === 3 ? 255 : (i * 7) % 256);
            const samples = new Float32Array(64).map((_, i) => Math.sin(i));
            noise.pixels(px, 8, 0, 0);
            noise.floats(samples, 0, 0);
            Array.from(px).join(',') + '|' + Array.from(samples).join(',');
            """
        let a = Page(), b = Page(), other = Page()
        helpers(a)
        helpers(b)
        helpers(other, seed: "00ff")
        let first = a.run(script).toString()
        #expect(first == b.run(script).toString())
        #expect(first != other.run(script).toString())
    }

    @Test func pixelNoiseIsIdempotentAndTouchesEveryVisiblePixelsLowBits() {
        let page = Page()
        helpers(page)
        let result = page.run("""
            const alpha = (p) => p % 4 === 1 ? 128 : (p % 4 === 2 ? 0 : 255);
            const raw = new Uint8ClampedArray(256 * 4).map((_, i) => i % 4 === 3 ? alpha(i >> 2) : (i * 13) % 256);
            const once = raw.slice(); noise.pixels(once, 16, 3, 5);
            const twice = once.slice(); noise.pixels(twice, 16, 3, 5);
            let lowOnly = true, opaque = 0, translucent = 0, transparentKept = true;
            for (let i = 0; i < raw.length; i++) {
              const a = raw[i | 3];
              if ((raw[i] ^ once[i]) & 254) lowOnly = false;
              if (i % 4 === 3 && raw[i] !== once[i]) lowOnly = false;
              if (raw[i] !== once[i] && a === 255) opaque++;
              if (raw[i] !== once[i] && a === 128) translucent++;
              if (raw[i] !== once[i] && a === 0) transparentKept = false;
            }
            [once.join() === twice.join(), lowOnly, opaque > 50, translucent > 20, transparentKept].join();
            """).toString()
        #expect(result == "true,true,true,true,true")
    }

    @Test func pixelNoiseFollowsPositionNotTheReadRectangle() {
        let page = Page()
        helpers(page)
        let result = page.run("""
            const full = new Uint8ClampedArray(80 * 70 * 4).fill(255);
            noise.pixels(full, 80, 0, 0);
            const part = new Uint8ClampedArray(3 * 2 * 4).fill(255);
            noise.pixels(part, 3, 66, 67);
            const wrapped = new Uint8ClampedArray(3 * 2 * 4).fill(255);
            noise.pixels(wrapped, 3, 2, 3);
            let same = true;
            for (let y = 0; y < 2; y++) for (let x = 0; x < 3; x++) for (let c = 0; c < 4; c++)
              if (part[(y * 3 + x) * 4 + c] !== full[((67 + y) * 80 + 66 + x) * 4 + c]) same = false;
            [same, part.join() === wrapped.join()].join();
            """).toString()
        #expect(result == "true,true")
    }

    @Test func sampleNoiseIsIdempotentAndLeavesSpecialValues() {
        let page = Page()
        helpers(page)
        let result = page.run("""
            const values = [0, -0, Infinity, -Infinity, NaN, 1e-45, 3e-45, 3.4028234663852886e38, -0.123, 0.5, 1, 42.75];
            const raw = new Float32Array(values);
            const once = raw.slice(); noise.floats(once, 0, 0);
            const twice = once.slice(); noise.floats(twice, 0, 0);
            const bits = (a) => Array.from(new Uint32Array(a.buffer)).join();
            const kept = [0, 1, 2, 3, 4].every((i) => Object.is(once[i], raw[i]));
            const ints = new Uint8Array(64).map((_, i) => i * 3);
            const i1 = ints.slice(); noise.ints(i1, 0, 9);
            const i2 = i1.slice(); noise.ints(i2, 0, 9);
            const halves = new Uint16Array([0, 0x8000, 0x7c00, 0xfc00, 0x7e00, 0x3c00, 0x3c01, 0x0001]);
            const h1 = halves.slice(); noise.halves(h1, 0, 2);
            const h2 = h1.slice(); noise.halves(h2, 0, 2);
            const hKept = [0, 1, 2, 3, 4].every((i) => h1[i] === halves[i]);
            const long = new Float32Array(70000).fill(0.375);
            const shifted = new Float32Array(10).fill(0.375);
            noise.floats(long, 0, 0); noise.floats(shifted, 69990, 0);
            const byPosition = shifted.every((v, i) => v === long[69990 + i]);
            [bits(once) === bits(twice), kept, Number.isFinite(once[7]), i1.join() === i2.join(),
             h1.join() === h2.join(), hKept, byPosition].join();
            """).toString()
        #expect(result == "true,true,true,true,true,true,true")
    }

    @Test func readPixelsNoiseNeverReturnsRawAndStopsAtTheWrittenArea() {
        let page = Page()
        helpers(page)
        let result = page.run("""
            const raw = new Uint8Array(4 + 16 * 16 * 4 + 8).fill(255);
            const out = raw.slice();
            noise.read(out, 0, 0, 16, 16, 0x1908, 0x1401, 4);
            let changed = 0;
            for (let i = 4; i < 4 + 1024; i++) if (out[i] !== raw[i]) changed++;
            const edges = [0, 1, 2, 3, 1028, 1029, 1030, 1031, 1032, 1035].every((i) => out[i] === raw[i]);
            const translucent = new Uint8Array(16 * 4).map((_, i) => i % 4 === 3 ? 100 : 255);
            noise.read(translucent, 0, 0, 4, 4, 0x1908, 0x1401);
            const transparent = new Uint8Array(16 * 4).map((_, i) => i % 4 === 3 ? 0 : 255);
            noise.read(transparent, 0, 0, 4, 4, 0x1908, 0x1401);
            const transparentOk = transparent.some((v, i) => i % 4 !== 3 && v === 254)
              && transparent.every((v, i) => i % 4 !== 3 || v === 0);
            const opaque = new Uint8Array(16 * 4).fill(255);
            noise.read(opaque, 0, 0, 4, 4, 0x1908, 0x1401);
            const sameBits = transparent.every((v, i) => i % 4 === 3 || v === opaque[i]);
            const f = new Float32Array(16).fill(0.25);
            noise.read(f, 0, 0, 2, 2, 0x1908, 0x1406);
            [changed > 0, edges, translucent.some((v) => v === 254), transparentOk, sameBits,
             f.some((v) => v !== 0.25)].join();
            """).toString()
        #expect(result == "true,true,true,true,true,true")
    }

    // MARK: Patched canvas

    @Test func readModifyWriteLoopStaysEqualForOpaquePixels() {
        let page = page()
        let result = page.run("""
            const ctx = new CanvasRenderingContext2D();
            const raw = ctx.s.px.slice();
            const first = ctx.getImageData(0, 0, 16, 8);
            ctx.putImageData(first, 0, 0);
            const second = ctx.getImageData(0, 0, 16, 8);
            let opaqueSame = true, translucentNoised = false;
            for (let i = 0; i < raw.length; i++) {
              const a = raw[i | 3];
              if (a === 255 && first.data[i] !== second.data[i]) opaqueSame = false;
              if (a === 128 && first.data[i] !== raw[i]) translucentNoised = true;
            }
            const part = ctx.getImageData(2, 3, 4, 2);
            let fits = true;
            for (let y = 0; y < 2; y++) for (let x = 0; x < 4; x++) for (let c = 0; c < 4; c++)
              if (part.data[(y * 4 + x) * 4 + c] !== first.data[((3 + y) * 16 + 2 + x) * 4 + c]) fits = false;
            [opaqueSame, first.data.join() !== raw.join(), translucentNoised, fits].join();
            """).toString()
        #expect(result == "true,true,true,true")
    }

    @Test func encodersReturnANoisedCopyAndLeaveThePageCanvas() {
        let page = page()
        page.run("""
            var canvas = new HTMLCanvasElement();
            var ctx = canvas.getContext('2d');
            var before = encode(canvas);
            var url = canvas.toDataURL();
            var expected = 'png:' + Array.from(ctx.getImageData(0, 0, 16, 8).data).join('.');
            var blob;
            canvas.toBlob((b) => { blob = b.data; });
            var off = new OffscreenCanvas(16, 8);
            var offCtx = off.getContext('2d');
            var offExpected = 'png:' + Array.from(offCtx.getImageData(0, 0, 16, 8).data).join('.');
            var offBlob;
            off.convertToBlob().then((b) => { offBlob = b.data; });
            """)
        let result = page.run("""
            [url !== before, url === expected, encode(canvas) === before, blob === url, offBlob === offExpected,
             offBlob !== encode(off), events.join()].join();
            """).toString()
        #expect(result == "true,true,true,true,true,true,lodgefingerprintread:canvas")
    }

    @Test func theCopyKeepsTheSourceColourSpace() {
        let page = page()
        let result = page.run("""
            const canvas = new HTMLCanvasElement();
            canvas.getContext('2d', { colorSpace: 'display-p3' });
            spaces = [];
            canvas.toDataURL();
            spaces.join();
            """).toString()
        #expect(result == "make:display-p3,get:display-p3")
    }

    @Test func anEncoderWithoutACopyGivesABlankResult() {
        let page = page()
        page.run("""
            var canvas = new HTMLCanvasElement();
            canvas.getContext('2d');
            var off = new OffscreenCanvas(16, 8);
            off.getContext('2d');
            noContext = true;
            var url = canvas.toDataURL();
            var blob = 'unset';
            var synchronous = true;
            canvas.toBlob((b) => { blob = [b, synchronous].join('/'); });
            synchronous = false;
            var failure;
            off.convertToBlob().then(() => { failure = 'resolved'; }, (e) => { failure = e.name; });
            """)
        #expect(page.run("[url, blob, failure].join()").toString() == "data:,,/false,EncodingError")
    }

    @Test func patchedFunctionsKeepNameAndLength() {
        let page = page()
        let result = page.run("""
            [CanvasRenderingContext2D.prototype.getImageData, HTMLCanvasElement.prototype.toDataURL,
             HTMLCanvasElement.prototype.toBlob, OffscreenCanvas.prototype.convertToBlob,
             HTMLCanvasElement.prototype.getContext, AudioBuffer.prototype.copyFromChannel,
             AnalyserNode.prototype.getFloatFrequencyData, OfflineAudioContext.prototype.startRendering,
             BaseAudioContext.prototype.decodeAudioData, open,
             Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'contentWindow').get]
              .map((f) => f.name + '/' + f.length).join();
            """).toString()
        #expect(
            result == "getImageData/4,toDataURL/2,toBlob/3,convertToBlob/1,getContext/2,copyFromChannel/3,"
                + "getFloatFrequencyData/1,startRendering/0,decodeAudioData/3,open/1,get/0")
    }

    @Test func eachApiTellsOncePerDocument() {
        let page = page()
        let result = page.run("""
            const ctx = new CanvasRenderingContext2D();
            ctx.getImageData(0, 0, 2, 2); ctx.getImageData(0, 0, 2, 2);
            const b = new AudioBuffer(1, 8);
            b.copyFromChannel(new Float32Array(8), 0); b.copyFromChannel(new Float32Array(8), 0);
            events.join();
            """).toString()
        #expect(result == "lodgefingerprintread:canvas,lodgefingerprintread:audio")
    }

    @Test func runningTwiceLeavesTheRealmAlone() {
        let page = page()
        page.run("var before = CanvasRenderingContext2D.prototype.getImageData;")
        page.run(FingerprintScript.pageSource(seed: "0000", site: Self.site, exactHost: false))
        #expect(page.run("CanvasRenderingContext2D.prototype.getImageData === before").toBool())
    }

    // MARK: Patched audio

    @Test func renderedBuffersAreNoisedInPlaceAndStayLive() {
        let page = page()
        page.run("""
            var made = new AudioBuffer(1, 64);
            var madeRaw = made.getChannelData(0).slice();
            var report;
            new OfflineAudioContext().startRendering().then((b) => {
              const live = b.getChannelData(0);
              const plain = new AudioBuffer(2, 64).getChannelData(0);
              const noised = live.some((v, i) => v !== plain[i]);
              const copy = new Float32Array(64); b.copyFromChannel(copy, 0);
              const copyMatches = copy.every((v, i) => Object.is(v, live[i]));
              live[3] = 0.75;
              const kept = b.getChannelData(0) === live && b.getChannelData(0)[3] === 0.75;
              const untouched = made.getChannelData(0).every((v, i) => Object.is(v, madeRaw[i]));
              report = [noised, copyMatches, kept, untouched].join();
            });
            """)
        #expect(page.run("report").toString() == "true,true,true,true")
    }

    @Test func copyFromChannelNoisesOnlyWhatItCopied() {
        let page = page()
        let result = page.run("""
            const b = new AudioBuffer(1, 16);
            const plain = b.getChannelData(0).slice();
            const dest = new Float32Array(12).fill(0.5);
            b.copyFromChannel(dest, 0, 10);
            const again = new Float32Array(12).fill(0.5);
            b.copyFromChannel(again, 0, 10);
            [dest.slice(0, 6).some((v, i) => v !== plain[10 + i]), dest.slice(6).every((v) => v === 0.5),
             dest.join() === again.join(), b.getChannelData(0).every((v, i) => Object.is(v, plain[i]))].join();
            """).toString()
        #expect(result == "true,true,true,true")
    }

    @Test func decodedBuffersAreNoisedOnceForCallbackAndPromise() {
        let page = page()
        page.run("""
            var plain = new AudioBuffer(1, 32).getChannelData(0);
            var noised = (b) => b.getChannelData(0).some((v, i) => v !== plain[i]);
            var context = new BaseAudioContext();
            var called, viaCallback, viaPromise;
            context.decodeAudioData(new ArrayBuffer(8), (b) => {
              called = noised(b);
              b.getChannelData(0)[2] = 0.125;
              viaCallback = b;
            }).then((b) => { viaPromise = [b === viaCallback, b.getChannelData(0)[2] === 0.125].join('/'); });
            var promiseOnly;
            context.decodeAudioData(new ArrayBuffer(8)).then((b) => { promiseOnly = noised(b); });
            """)
        #expect(page.run("[called, viaPromise, promiseOnly].join()").toString() == "true,true/true,true")
    }

    @Test func analyserReadsAreNoisedWithinTheirLength() {
        let page = page()
        let result = page.run("""
            const node = new AnalyserNode();
            const f = new Float32Array(10).fill(5); node.getFloatFrequencyData(f);
            const plain = Array.from({ length: 8 }, (_, i) => Math.fround(-30.25 - i));
            const bytes = new Uint8Array(10).fill(9); node.getByteFrequencyData(bytes);
            [f.slice(0, 8).some((v, i) => v !== plain[i]), f[8] === 5 && f[9] === 5,
             bytes[8] === 9 && bytes[9] === 9].join();
            """).toString()
        #expect(result == "true,true,true")
    }

    // MARK: Child realms

    /// Reaches `frame` / `popup` with `reach`, then reads its 2D context twice; the realm must be patched once and
    /// tell on the top document.
    private func realmReached(by reach: String, realm: String) -> String {
        let page = page()
        return page.run("""
            const reached = \(reach);
            const patched = \(realm).CanvasRenderingContext2D.prototype.getImageData;
            \(reach);
            const ctx = new \(realm).CanvasRenderingContext2D();
            const raw = ctx.s.px.slice();
            const read = ctx.getImageData(0, 0, 4, 4);
            ctx.getImageData(0, 0, 4, 4);
            [reached === \(realm) || reached === \(realm).document,
             \(realm).CanvasRenderingContext2D.prototype.getImageData === patched, read.data.join() !== raw.join(),
             events.join()].join();
            """).toString()
    }

    @Test func aFrameReachedByContentWindowIsPatched() {
        #expect(realmReached(by: "new HTMLIFrameElement().contentWindow", realm: "frame")
            == "true,true,true,lodgefingerprintread:canvas")
    }

    @Test func aFrameReachedByContentDocumentIsPatched() {
        #expect(realmReached(by: "new HTMLIFrameElement().contentDocument", realm: "frame")
            == "true,true,true,lodgefingerprintread:canvas")
    }

    @Test func aPopupReachedByOpenIsPatched() {
        #expect(realmReached(by: "open('https://example.com/')", realm: "popup")
            == "true,true,true,lodgefingerprintread:canvas")
    }

    @Test func aRealmThatThrowsWhilePatchedStillComesBack() {
        let page = page()
        let result = page.run("""
            frame = { location: { protocol: 'about:' }, parent: globalThis };
            Object.defineProperty(frame, 'AudioBuffer', { get() { throw new Error('boom'); } });
            new HTMLIFrameElement().contentWindow === frame;
            """)
        #expect(result.toBool())
    }
}
