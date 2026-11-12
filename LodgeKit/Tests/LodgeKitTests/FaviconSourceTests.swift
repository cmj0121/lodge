import Foundation
import Testing

@testable import LodgeKit

@Suite struct FaviconSourceTests {
    private let page = URL(string: "https://example.com/docs/page.html")!
    private typealias Link = FaviconSource.Link

    @Test func withoutLinksFallsBackToFaviconIcoAtTheOrigin() {
        #expect(FaviconSource.candidate(page: page, links: []) == URL(string: "https://example.com/favicon.ico"))
    }

    @Test func fallbackKeepsAnExplicitPort() {
        let local = URL(string: "http://localhost:8080/app")!
        #expect(FaviconSource.candidate(page: local, links: []) == URL(string: "http://localhost:8080/favicon.ico"))
    }

    @Test func prefersAnSVGIcon() {
        let links = [
            Link(rel: "icon", href: "/a.png", sizes: "32x32"),
            Link(rel: "icon", href: "/a.svg"),
        ]
        #expect(FaviconSource.candidate(page: page, links: links) == URL(string: "https://example.com/a.svg"))
    }

    @Test func picksTheDeclaredSizeClosestTo32() {
        let links = [
            Link(rel: "icon", href: "/16.png", sizes: "16x16"),
            Link(rel: "icon", href: "/192.png", sizes: "192x192"),
            Link(rel: "icon", href: "/48.png", sizes: "48x48"),
        ]
        #expect(FaviconSource.candidate(page: page, links: links) == URL(string: "https://example.com/48.png"))
    }

    @Test func shortcutIconCountsAsAnIcon() {
        let links = [Link(rel: "Shortcut Icon", href: "fav.ico")]
        #expect(FaviconSource.candidate(page: page, links: links) == URL(string: "https://example.com/docs/fav.ico"))
    }

    @Test func appleTouchIconIsUsedOnlyWithoutAPlainIcon() {
        let touch = Link(rel: "apple-touch-icon", href: "/touch.png")
        #expect(FaviconSource.candidate(page: page, links: [touch]) == URL(string: "https://example.com/touch.png"))
        let both = [touch, Link(rel: "icon", href: "/icon.png")]
        #expect(FaviconSource.candidate(page: page, links: both) == URL(string: "https://example.com/icon.png"))
    }

    @Test func dataURLIconsAreAllowed() {
        let links = [Link(rel: "icon", href: "data:image/png;base64,AAAA")]
        #expect(FaviconSource.candidate(page: page, links: links)?.scheme == "data")
    }

    @Test func scriptAndFileHrefsAreSkipped() {
        let links = [
            Link(rel: "icon", href: "javascript:alert(1)"),
            Link(rel: "icon", href: "file:///etc/passwd"),
        ]
        #expect(FaviconSource.candidate(page: page, links: links) == URL(string: "https://example.com/favicon.ico"))
    }

    @Test func nonHTTPPagesGetNoIcon() {
        #expect(FaviconSource.candidate(page: URL(string: "about:blank")!, links: []) == nil)
        #expect(FaviconSource.candidate(page: URL(string: "file:///tmp/a.html")!, links: []) == nil)
    }
}

@Suite struct FaviconFetchPolicyTests {
    @Test func scriptResultParsesALinkObject() {
        let raw: Any = ["rel": "icon", "href": "/a.png", "sizes": "32x32"]
        #expect(FaviconSource.Link(scriptResult: raw) == FaviconSource.Link(rel: "icon", href: "/a.png", sizes: "32x32"))
    }

    @Test func scriptResultWithoutAnHrefIsDropped() {
        #expect(FaviconSource.Link(scriptResult: ["rel": "icon", "href": ""]) == nil)
        #expect(FaviconSource.Link(scriptResult: ["rel": "icon"]) == nil)
        #expect(FaviconSource.Link(scriptResult: "not an object") == nil)
    }

    @Test func acceptsASmallImage() {
        #expect(FaviconSource.accepts(statusCode: 200, mimeType: "image/png", expectedLength: 1_024))
        #expect(FaviconSource.accepts(statusCode: nil, mimeType: "image/svg+xml", expectedLength: -1))
    }

    @Test func refusesErrorsNonImagesUntypedAndOversizedBodies() {
        #expect(!FaviconSource.accepts(statusCode: 404, mimeType: "image/png", expectedLength: 10))
        #expect(!FaviconSource.accepts(statusCode: 200, mimeType: "text/html", expectedLength: 10))
        #expect(!FaviconSource.accepts(statusCode: 200, mimeType: nil, expectedLength: 10))
        #expect(
            !FaviconSource.accepts(
                statusCode: 200, mimeType: "image/png", expectedLength: Int64(FaviconSource.maxBytes) + 1))
    }
}
