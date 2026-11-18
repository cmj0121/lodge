import Foundation

/// Which kind of fingerprint a page read (D4).
public enum FingerprintAPI: String, Sendable {
    case canvas, webgl, audio
}

/// The page-world patch that gives each site its own canvas, WebGL and audio fingerprint, the isolated-world relay
/// that reports a read, and how the relay's messages read (D4).
///
/// The patch forces the low bit of each colour channel of every pixel with alpha > 0, and of each non-zero finite
/// audio sample, to a bit drawn from (seed, position) out of tables built once per realm. That noise is idempotent,
/// g(g(x)) = g(x): reading what was read changes nothing, so for opaque pixels a `getImageData` → `putImageData` →
/// `getImageData` loop stays equal (a translucent pixel's round trip through premultiplied alpha is lossy natively
/// too), and the same seed gives the same answer every time. Canvas and copy APIs return noised copies and never
/// touch the page's canvas; a copy that cannot be made gives a blank result, never the raw encoding. `getChannelData`
/// stays live, and noise goes in place only on buffers `startRendering` / `decodeAudioData` hand back, never on buffers
/// the page creates. `srcdoc` iframes and `window.open(url)` popups are patched when the page first reaches their
/// realm (D6); a realm already patched, natively or so, is left alone.
///
/// Limits: an `ImageBitmap` from `createImageBitmap` uploaded to WebGL, pixel buffer objects and `getBufferSubData`,
/// `captureStream`; methods a page captured from a realm before it was patched; web workers, service workers and
/// `OffscreenCanvas` in workers; cross-origin realms (they get their own native injection). Left out: hiding the
/// event or the patches from the page (M2).
public enum FingerprintScript {
    /// `WKContentWorld.world(name:)` of the relay; the patch itself runs in the page world.
    public static let worldName = "lodge.fingerprint"
    public static let handlerName = "lodgeFingerprint"
    /// The `CustomEvent` the patch dispatches on `document`, at most once per api per document, its `detail` the api
    /// name as a string: a page-world object can read as null from an isolated world, a primitive cannot (D4).
    public static let eventName = "lodgefingerprintread"

    /// Isolated world, `.atDocumentStart`, `forMainFrameOnly: false`: relays each read api once per document, and
    /// again, for every api the document read, when it comes back from the back/forward cache (`pageshow` with
    /// `persisted`), since its commit cleared what the app knew. A forged event only lights the indicator.
    public static let relaySource = """
        (() => {
          const handlers = window.webkit && window.webkit.messageHandlers;
          const handler = handlers && handlers.\(handlerName);
          if (!handler) { return; }
          const apis = new Set(['canvas', 'webgl', 'audio']);
          const read = new Set();
          const sent = new Set();
          const send = (api) => {
            if (sent.has(api)) { return; }
            sent.add(api);
            try { handler.postMessage({ api: api }); } catch (_) {}
          };
          document.addEventListener('\(eventName)', (e) => {
            const api = e.detail;
            if (typeof api !== 'string' || !apis.has(api)) { return; }
            read.add(api);
            send(api);
          }, { capture: true, passive: true });
          window.addEventListener('pageshow', (e) => {
            if (!e.persisted) { return; }
            sent.clear();
            read.forEach(send);
          }, { capture: true, passive: true });
        })();
        """

    /// Page world, `.atDocumentStart`, `forMainFrameOnly: false`, before any page script. `seed` is the view's hex
    /// seed (D1) and `site` the registrable domain it was made for, both used as literals: anything but hex digits is
    /// dropped from the seed, anything but lower-case letters, digits, `.`, `-`, `:`, `[` and `]` from the site. A
    /// document whose top frame's host is not `site`, nor below it unless `exactHost` (the site is a host with no
    /// registrable domain of its own: a public suffix, a host with no suffix, an IP), as an old page still live after
    /// the response decision for the next site re-seeded the view (D7), gets a throwaway random seed instead; a child
    /// realm the patch reaches shares its verdict. A frame under a sandboxed top document, whose last ancestor origin
    /// is "null", takes `top.location`'s host, and when that cannot be read accepts `site` so it stays stable: such a
    /// frame created by an old sandboxed page in the re-seed window reads the next site's seed, an accepted gap. Runs
    /// without throwing where canvas, WebGL or audio are missing.
    public static func pageSource(seed: String, site: String, exactHost: Bool) -> String {
        """
        (() => {
          const SEED = '\(hex(seed))';
          const SITE = '\(siteLiteral(site))';
          const EXACT = \(exactHost);
          const home = globalThis;
          const bare = (host) => String(host).toLowerCase().replace(/^\\[|\\]$/g, '').replace(/\\.$/, '');
          // The top frame's host: the last ancestor origin's in a frame, the document's origin's at the top, which a
          // blank popup inherits from its opener.
          const topHost = () => {
            try {
              if (home.parent !== home) {
                const ancestors = home.location.ancestorOrigins;
                if (!ancestors || !ancestors.length) { return ''; }
                const last = ancestors[ancestors.length - 1];
                if (last !== 'null') { return new URL(last).hostname; }
                try { return home.top.location.hostname; } catch (_) { return SITE; }
              }
              const origin = home.origin;
              return typeof origin === 'string' && origin !== 'null' ? new URL(origin).hostname : home.location.hostname;
            } catch (_) { return ''; }
          };
          const fits = (host) => {
            const h = bare(host);
            const s = bare(SITE);
            return s !== '' && (h === s || (!EXACT && h.endsWith('.' + s)));
          };
          const throwaway = () => {
            const bytes = new Uint8Array(32);
            try {
              home.crypto.getRandomValues(bytes);
            } catch (_) {
              for (let i = 0; i < bytes.length; i++) { bytes[i] = Math.floor(Math.random() * 256); }
            }
            return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
          };
          const noise = (\(noiseFactory))(fits(topHost()) ? SEED : throwaway());
          const MARK = Symbol.for('lodge.fingerprint');
          const TOLD = Symbol.for('lodge.fingerprint.told');
          const own = (o, k) => (o ? Object.getOwnPropertyDescriptor(o, k) : undefined);
          const keep = (wrapper, original) => {
            Object.defineProperty(wrapper, 'name', { value: original.name, configurable: true });
            Object.defineProperty(wrapper, 'length', { value: original.length, configurable: true });
            return wrapper;
          };
          const method = (proto, key, wrap) => {
            const d = own(proto, key);
            if (!d || typeof d.value !== 'function') { return; }
            d.value = keep(wrap(d.value), d.value);
            Object.defineProperty(proto, key, d);
          };
          const getter = (proto, key, wrap) => {
            const d = own(proto, key);
            if (!d || typeof d.get !== 'function') { return; }
            d.get = keep(wrap(d.get), d.get);
            Object.defineProperty(proto, key, d);
          };
          const step = (f) => { try { f(); } catch (_) {} };
          const rawDispatch = home.EventTarget && home.EventTarget.prototype.dispatchEvent;
          const makeTell = (target) => (api) => {
            try {
              const doc = target();
              if (!doc) { return; }
              let told = own(doc, TOLD) && own(doc, TOLD).value;
              if (!told) {
                told = new Set();
                Object.defineProperty(doc, TOLD, { value: told });
              }
              if (told.has(api)) { return; }
              told.add(api);
              const Event = (doc.defaultView || home).CustomEvent;
              (rawDispatch || doc.dispatchEvent).call(doc, new Event('\(eventName)', { detail: api }));
            } catch (_) {}
          };
          // A blank child realm reports on the nearest document it is not blank in (D4).
          const homeDocument = () => {
            let w = home;
            try {
              while (w.location && w.location.protocol === 'about:' && w.parent && w.parent !== w) {
                void w.parent.document;
                w = w.parent;
              }
            } catch (_) {}
            return w.document;
          };
          const patch = (win, tell) => {
            try {
              if (Object.prototype.hasOwnProperty.call(win, MARK)) { return; }
              Object.defineProperty(win, MARK, { value: true });
            } catch (_) { return; }
            try { patchRealm(win, tell); } catch (_) {}
          };
          const patchRealm = (win, tell) => {
            const proto = (name) => { const c = win[name]; return c && c.prototype; };
            const unique = (names) => [...new Set(names.map(proto).filter(Boolean))];
            const canvas = proto('HTMLCanvasElement');
            const offscreen = proto('OffscreenCanvas');
            const ctx2d = proto('CanvasRenderingContext2D');
            const offscreen2d = proto('OffscreenCanvasRenderingContext2D');
            const glProtos = unique(['WebGLRenderingContext', 'WebGL2RenderingContext']);
            const value = (o, k) => own(o, k) && own(o, k).value;
            const raw2d = new Map();
            for (const p of [ctx2d, offscreen2d]) {
              if (p) {
                raw2d.set(p, { get: value(p, 'getImageData'), put: value(p, 'putImageData'), draw: value(p, 'drawImage') });
              }
            }
            const rawGetContext = value(canvas, 'getContext');
            const rawOffscreenGetContext = value(offscreen, 'getContext');
            const rawCreate = value(win.Document && win.Document.prototype, 'createElement');

            const contexts = new WeakMap();
            const isGL = (c) => glProtos.some((g) => g.isPrototypeOf(c));
            const kind = (c) => (contexts.has(c) && isGL(contexts.get(c)) ? 'webgl' : 'canvas');
            const colorSpace = (c) => {
              try {
                const context = contexts.get(c);
                if (!context) { return 'srgb'; }
                const settings = typeof context.getContextAttributes === 'function' && context.getContextAttributes();
                return (settings && settings.colorSpace) || context.drawingBufferColorSpace || 'srgb';
              } catch (_) { return 'srgb'; }
            };
            for (const p of [canvas, offscreen]) {
              step(() => method(p, 'getContext', (orig) => ({ getContext(...a) {
                const context = orig.apply(this, a);
                if (context && !contexts.has(this)) { contexts.set(this, context); }
                return context;
              } }).getContext));
            }
            // A noised copy of the source on a scratch canvas in its colour space; null when there is nothing to copy,
            // false when no copy can be made (the caller then gives a blank result). Read errors (a tainted canvas)
            // throw as natively.
            const scratch = (source, isOffscreen) => {
              const w = source.width;
              const h = source.height;
              if (!(w > 0 && h > 0)) { return null; }
              const space = colorSpace(source);
              const r = raw2d.get(isOffscreen ? offscreen2d : ctx2d);
              let copy;
              let context;
              try {
                if (isOffscreen) {
                  copy = new win.OffscreenCanvas(w, h);
                } else {
                  copy = rawCreate.call(win.document, 'canvas');
                  copy.width = w;
                  copy.height = h;
                }
                context = (isOffscreen ? rawOffscreenGetContext : rawGetContext).call(copy, '2d', { colorSpace: space });
              } catch (_) { return false; }
              if (!context || !r || !r.get || !r.put || !r.draw) { return false; }
              r.draw.call(context, source, 0, 0);
              const image = r.get.call(context, 0, 0, w, h, { colorSpace: space });
              noise.pixels(image.data, w, 0, 0);
              r.put.call(context, image, 0, 0);
              return copy;
            };
            step(() => method(canvas, 'toDataURL', (orig) => ({ toDataURL(...a) {
              const copy = scratch(this, false);
              tell(kind(this));
              return copy === false ? 'data:,' : orig.apply(copy || this, a);
            } }).toDataURL));
            step(() => method(canvas, 'toBlob', (orig) => ({ toBlob(...a) {
              if (typeof a[0] !== 'function') { return orig.apply(this, a); }
              const copy = scratch(this, false);
              tell(kind(this));
              if (copy === false) {
                const done = a[0];
                win.Promise.resolve().then(() => done(null));
                return undefined;
              }
              return orig.apply(copy || this, a);
            } }).toBlob));
            step(() => method(offscreen, 'convertToBlob', (orig) => ({ convertToBlob(...a) {
              let copy;
              try { copy = scratch(this, true); } catch (e) { return win.Promise.reject(e); }
              tell(kind(this));
              if (copy === false) {
                return win.Promise.reject(new win.DOMException('The canvas could not be encoded.', 'EncodingError'));
              }
              return orig.apply(copy || this, a);
            } }).convertToBlob));
            for (const p of [ctx2d, offscreen2d]) {
              step(() => method(p, 'getImageData', (orig) => ({ getImageData(...a) {
                const image = orig.apply(this, a);
                tell('canvas');
                const x = Math.floor(Number(a[2]) < 0 ? Number(a[0]) + Number(a[2]) : Number(a[0]));
                const y = Math.floor(Number(a[3]) < 0 ? Number(a[1]) + Number(a[3]) : Number(a[1]));
                noise.pixels(image.data, image.width, x, y);
                return image;
              } }).getImageData));
            }
            for (const p of glProtos) {
              step(() => method(p, 'readPixels', (orig) => ({ readPixels(...a) {
                const result = orig.apply(this, a);
                tell('webgl');
                if (ArrayBuffer.isView(a[6])) { noise.read(a[6], a[0], a[1], a[2], a[3], a[4], a[5], a[7]); }
                return result;
              } }).readPixels));
            }

            const buffer = proto('AudioBuffer');
            const rawChannel = value(buffer, 'getChannelData');
            const rendered = new WeakSet();
            const render = (b) => {
              if (!b || !rawChannel || rendered.has(b)) { return b; }
              try {
                rendered.add(b);
                for (let c = 0; c < b.numberOfChannels; c++) { noise.floats(rawChannel.call(b, c), 0, c); }
                tell('audio');
              } catch (_) {}
              return b;
            };
            step(() => method(buffer, 'copyFromChannel', (orig) => ({ copyFromChannel(...a) {
              const result = orig.apply(this, a);
              tell('audio');
              const start = (Number(a[2]) || 0) >>> 0;
              noise.floats(a[0], start, a[1] >>> 0, this.length - start);
              return result;
            } }).copyFromChannel));
            const analyser = proto('AnalyserNode');
            [['getFloatFrequencyData', 'floats', 'frequencyBinCount'], ['getFloatTimeDomainData', 'floats', 'fftSize'],
             ['getByteFrequencyData', 'ints', 'frequencyBinCount'], ['getByteTimeDomainData', 'ints', 'fftSize']]
              .forEach(([key, form, size], salt) => step(() => method(analyser, key, (orig) => ({ [key](...a) {
                const result = orig.apply(this, a);
                tell('audio');
                noise[form](a[0], 0, 100 + salt, this[size]);
                return result;
              } })[key])));
            for (const p of unique(['OfflineAudioContext', 'webkitOfflineAudioContext'])) {
              step(() => method(p, 'startRendering', (orig) => ({ startRendering(...a) {
                const result = orig.apply(this, a);
                return result && typeof result.then === 'function' ? result.then(render) : result;
              } }).startRendering));
            }
            step(() => getter(proto('OfflineAudioCompletionEvent'), 'renderedBuffer', (orig) => ({ renderedBuffer() {
              return render(orig.call(this));
            } }).renderedBuffer));
            for (const p of unique(['BaseAudioContext', 'AudioContext', 'OfflineAudioContext', 'webkitAudioContext',
              'webkitOfflineAudioContext'])) {
              step(() => method(p, 'decodeAudioData', (orig) => ({ decodeAudioData(...a) {
                if (typeof a[1] === 'function') {
                  const done = a[1];
                  a[1] = function (...b) { render(b[0]); return done.apply(this, b); };
                }
                const result = orig.apply(this, a);
                return result && typeof result.then === 'function' ? result.then(render) : result;
              } }).decodeAudioData));
            }

            // Realms WebKit does not inject into natively: srcdoc iframes, window.open(url) popups (D6).
            const iframe = proto('HTMLIFrameElement');
            const rawContentWindow = own(iframe, 'contentWindow') && own(iframe, 'contentWindow').get;
            const reach = (w) => { if (w) { patch(w, tell); } return w; };
            step(() => getter(iframe, 'contentWindow', (orig) => ({ contentWindow() {
              return reach(orig.call(this));
            } }).contentWindow));
            step(() => getter(iframe, 'contentDocument', (orig) => ({ contentDocument() {
              if (rawContentWindow) { reach(rawContentWindow.call(this)); }
              return orig.call(this);
            } }).contentDocument));
            step(() => {
              let holder = win;
              while (holder && !own(holder, 'open')) { holder = Object.getPrototypeOf(holder); }
              method(holder, 'open', (orig) => ({ open(...a) { return reach(orig.apply(this, a)); } }).open);
            });
          };
          patch(home, makeTell(homeDocument));
        })();
        """
    }

    /// A JS expression for the pure, seeded noise helpers the patch uses. Each forces a low bit to one looked up by
    /// position in a table hashed from the seed once, so applying one twice is the same as once: pixels by
    /// `(x & 63, y & 63, channel)`, samples and other elements by `(position + salt) & 65535`.
    static func noiseSource(seed: String) -> String {
        "(\(noiseFactory))('\(hex(seed))')"
    }

    private static func hex(_ seed: String) -> String {
        String(seed.unicodeScalars.filter { "0123456789abcdefABCDEF".unicodeScalars.contains($0) })
    }

    private static func siteLiteral(_ site: String) -> String {
        let allowed = "abcdefghijklmnopqrstuvwxyz0123456789.-:[]".unicodeScalars
        return String(site.lowercased().unicodeScalars.filter { allowed.contains($0) })
    }

    /// A JS function of the hex seed that returns the noise helpers `noiseSource` describes.
    private static let noiseFactory = """
            (SEED) => {
              const fold = (basis) => {
                let h = basis | 0;
                for (let i = 0; i < SEED.length; i++) { h = Math.imul(h ^ SEED.charCodeAt(i), 0x01000193); }
                return h;
              };
              const k0 = fold(0x811c9dc5);
              const k1 = fold(0x2545f491);
              const bit = (salt, a, b) => {
                let h = Math.imul(k0 ^ salt, 0x27d4eb2d);
                h = Math.imul(h ^ (a | 0), 0x9e3779b1);
                h ^= h >>> 15;
                h = Math.imul(h ^ (b | 0) ^ k1, 0x85ebca77);
                h ^= h >>> 13;
                h = Math.imul(h, 0xc2b2ae35);
                h ^= h >>> 16;
                return h & 1;
              };
              let tile = null;
              const tileBits = () => {
                if (!tile) {
                  tile = new Uint8Array(64 * 64 * 3);
                  for (let y = 0; y < 64; y++) for (let x = 0; x < 64; x++) for (let c = 0; c < 3; c++) {
                    tile[(y * 64 + x) * 3 + c] = bit(1, x, y * 4 + c);
                  }
                }
                return tile;
              };
              let line = null;
              const lineBits = () => {
                if (!line) {
                  line = new Uint8Array(65536);
                  for (let i = 0; i < 65536; i++) { line[i] = bit(0, i, 0); }
                }
                return line;
              };
              const origin = (base, salt) => ((Number(base) || 0) + Math.imul(salt | 0, 7919)) | 0;
              const tag = (v) => Object.prototype.toString.call(v).slice(8, -1);
              const span = (array, count) =>
                Math.max(0, Math.min(array.length, count === undefined ? array.length : Number(count) || 0));
              // RGBA bytes whose top-left pixel sits at (x0, y0) in a surface `width` pixels wide; alpha is kept, and
              // fully transparent pixels are left as they are unless `everyPixel` (readPixels: a shader can write colour
              // with alpha 0, and nothing writes it back through premultiplied alpha).
              const pixels = (data, width, x0, y0, everyPixel) => {
                if (!(width > 0)) { return; }
                const t = tileBits();
                const left = x0 | 0;
                let i = 0;
                for (let y = y0 | 0; i + 3 < data.length; y++) {
                  const row = (y & 63) * 192;
                  for (let x = left, end = left + width; x < end && i + 3 < data.length; x++, i += 4) {
                    if (data[i + 3] === 0 && !everyPixel) { continue; }
                    const k = row + (x & 63) * 3;
                    data[i] = (data[i] & 254) | t[k];
                    data[i + 1] = (data[i + 1] & 254) | t[k + 1];
                    data[i + 2] = (data[i + 2] & 254) | t[k + 2];
                  }
                }
              };
              // Integer elements; element i stands at position base + i.
              const ints = (array, base, salt, count) => {
                if (!array || typeof array.length !== 'number') { return; }
                const l = lineBits();
                const o = origin(base, salt);
                const n = span(array, count);
                for (let i = 0; i < n; i++) { array[i] = (array[i] & -2) | l[(o + i) & 65535]; }
              };
              // Float32 samples: the mantissa's low bit, leaving zeros, infinities and NaN as they are.
              const floats = (array, base, salt, count) => {
                if (tag(array) !== 'Float32Array') { return; }
                const l = lineBits();
                const o = origin(base, salt);
                const n = span(array, count);
                const bits = new Uint32Array(array.buffer, array.byteOffset, n);
                for (let i = 0; i < n; i++) {
                  const u = bits[i];
                  if ((u & 0x7f800000) === 0x7f800000 || (u & 0x7fffffff) === 0) { continue; }
                  bits[i] = (u & -2) | l[(o + i) & 65535];
                }
              };
              // Half floats in Uint16 elements, by the same rule as `floats`.
              const halves = (array, base, salt, count) => {
                const l = lineBits();
                const o = origin(base, salt);
                const n = span(array, count);
                for (let i = 0; i < n; i++) {
                  const u = array[i];
                  if ((u & 0x7c00) === 0x7c00 || (u & 0x7fff) === 0) { continue; }
                  array[i] = (u & -2) | l[(o + i) & 65535];
                }
              };
              const channels = { 0x1908: 4, 0x8d99: 4, 0x1907: 3, 0x8d98: 3, 0x8227: 2, 0x8228: 2, 0x190a: 2,
                0x1903: 1, 0x8d94: 1, 0x1906: 1, 0x1909: 1 };
              const packed = new Set([0x8363, 0x8033, 0x8034, 0x8368, 0x8c3b, 0x8c3e, 0x84fa]);
              // What `readPixels(x, y, w, h, format, type, view, offset)` wrote into `view`.
              const read = (view, x, y, w, h, format, type, offset) => {
                if (typeof view.subarray !== 'function') { return; }
                const start = Math.max(0, Number(offset) || 0);
                const ch = packed.has(type) ? 1 : (channels[format] || 4);
                const area = view.subarray(start, start + Math.max(0, w | 0) * Math.max(0, h | 0) * ch);
                const t = tag(view);
                if ((t === 'Uint8Array' || t === 'Uint8ClampedArray') && format === 0x1908) {
                  pixels(area, w | 0, x | 0, y | 0, true);
                } else if (t === 'Float32Array') {
                  floats(area, 0, 2);
                } else if (type === 0x140b || type === 0x8d61) {
                  halves(area, 0, 2);
                } else {
                  ints(area, 0, 2);
                }
              };
              return { pixels: pixels, ints: ints, floats: floats, halves: halves, read: read };
            }
            """

    /// Decodes a relay message body `{api: "canvas"|"webgl"|"audio"}`; anything else is nil.
    public static func api(from body: Any) -> FingerprintAPI? {
        guard let body = body as? [String: Any], body.count == 1, let api = body["api"] as? String else { return nil }
        return FingerprintAPI(rawValue: api)
    }
}
