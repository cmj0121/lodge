import Foundation
import Testing

@testable import LodgeKit

@Suite struct ExternalLinkTests {
    @Test(arguments: [
        "https://example.com/a?b=c#d", "http://localhost:3000", "HTTPS://EXAMPLE.COM", "http://127.0.0.1/",
        "https://[::1]:8443/x",
    ])
    func acceptsWebPages(url: String) throws {
        #expect(ExternalLink.accepts(try #require(URL(string: url))))
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "about:blank", "mailto:me@example.com",
        "ftp://example.com/f", "lodge://open", "http:/nohost", "https://", "x-apple-helpviewer://a",
    ])
    func ignoresEverythingElse(url: String) throws {
        #expect(!ExternalLink.accepts(try #require(URL(string: url))))
    }

    @Test func filterKeepsOrderAndCountsTheIgnored() throws {
        let urls = try ["https://b.example", "file:///tmp/x", "http://a.example", "mailto:x@y.z"].map {
            try #require(URL(string: $0))
        }
        let result = ExternalLink.filter(urls)
        #expect(result.accepted == [urls[0], urls[2]])
        #expect(result.ignored == 2)
    }

    @Test func filterOfNothingIsEmpty() {
        let result = ExternalLink.filter([])
        #expect(result.accepted.isEmpty && result.ignored == 0)
    }
}
