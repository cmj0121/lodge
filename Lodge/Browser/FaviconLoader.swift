import AppKit
import LodgeKit
import WebKit

/// Keeps one tab's favicon current: drops it when the tab commits a page on another origin, and
/// loads the page's declared icon when a new page finishes. The fetch runs outside every website
/// data store and sends no cookies or credentials, so it cannot tie the tab's identity to the
/// icon request. Each anonymous tab's store fetches on a session of its own (`WebViewRegistry.faviconSession`), so
/// a server cannot link two of them by a shared connection or TLS session.
@MainActor
final class FaviconLoader {
    /// Default's and the custom workspaces' icons.
    static let shared = makeSession()

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }

    /// Reads `link[rel~=icon]` in an isolated script world, so page scripts cannot change what it returns.
    private static let script = """
        return Array.from(document.querySelectorAll('link[rel]'))
            .filter(l => /icon/i.test(l.rel))
            .map(l => ({ rel: l.rel, href: l.getAttribute('href') || '', sizes: l.getAttribute('sizes') }));
        """

    /// Receives the decoded icon, or nil when the tab's icon is dropped.
    private let apply: @MainActor (NSImage?) -> Void
    private let session: URLSession
    private var origin: Origin?
    private var scrapedPage: URL?
    private var iconURL: URL?
    private var task: Task<Void, Never>?

    init(session: URLSession, apply: @escaping @MainActor (NSImage?) -> Void) {
        self.session = session
        self.apply = apply
    }

    /// A main-frame page committed: a different origin drops the old icon.
    func pageCommitted(_ url: URL?) {
        let next = url.map(Origin.init(url:))
        guard next != origin else { return }
        origin = next
        task?.cancel()
        scrapedPage = nil
        iconURL = nil
        apply(nil)
    }

    /// A page finished: reads its icon links once per page and loads the icon if it is a new one.
    func pageFinished(in webView: WKWebView) {
        guard let page = webView.url, page != scrapedPage else { return }
        scrapedPage = page
        task?.cancel()
        task = Task { [weak self, session] in
            let raw = try? await webView.callAsyncJavaScript(Self.script, contentWorld: .defaultClient)
            let links = (raw as? [Any] ?? []).compactMap(FaviconSource.Link.init(scriptResult:))
            guard let self, !Task.isCancelled, let url = FaviconSource.candidate(page: page, links: links),
                url != self.iconURL
            else { return }
            guard let data = await Self.fetch(url, on: session), !Task.isCancelled, let image = NSImage(data: data)
            else { return }
            // Recorded only once shown, so a cancelled or failed fetch is tried again on the next page.
            self.iconURL = url
            self.apply(image)
        }
    }

    /// Checks the response before reading the body, and stops reading once it passes the size cap.
    private nonisolated static func fetch(_ url: URL, on session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
            FaviconSource.accepts(
                statusCode: (response as? HTTPURLResponse)?.statusCode, mimeType: response.mimeType,
                expectedLength: response.expectedContentLength)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > FaviconSource.maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}
