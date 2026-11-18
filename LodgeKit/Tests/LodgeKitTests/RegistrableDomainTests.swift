import Foundation
import Testing

@testable import LodgeKit

@Suite struct RegistrableDomainTests {
    private func domain(_ string: String) -> String? {
        RegistrableDomain.of(URL(string: string)!)
    }

    @Test func subdomainMapsToItsRegistrableDomain() {
        #expect(domain("https://www.example.co.uk/a") == "example.co.uk")
        #expect(domain("http://news.example.com") == "example.com")
    }

    @Test func hostIsLowerCased() {
        #expect(domain("https://WWW.Example.COM") == "example.com")
    }

    /// `github.io` is itself a public suffix, so two of its sites are two domains.
    @Test func sitesOnAPrivateSuffixStayApart() {
        #expect(domain("https://a.github.io") == "a.github.io")
        #expect(domain("https://a.github.io") != domain("https://b.github.io"))
    }

    @Test(arguments: [
        ("http://127.0.0.1:8080", "127.0.0.1"), ("http://10.0.0.1", "10.0.0.1"), ("http://[::1]:8000", "::1"),
        ("http://localhost:3000", "localhost"), ("https://intranet", "intranet"),
    ])
    func ipAndSuffixlessHostsMapToThemselves(url: String, expected: String) {
        #expect(domain(url) == expected)
    }

    @Test(arguments: ["file:///Users/me/index.html", "about:blank", "data:text/html,hi", "ftp://example.com", "https:///path"])
    func nonWebURLsHaveNone(url: String) {
        #expect(domain(url) == nil)
    }

    @Test(arguments: [
        ("github.io", true), ("localhost", true), ("intranet", true), ("127.0.0.1", true), ("::1", true),
        ("example.com", false), ("example.com.au", false), ("a.github.io", false), ("Example.COM", false),
    ])
    func wholeHostsAreSitesWithNoDomainBelowThem(site: String, whole: Bool) {
        #expect(RegistrableDomain.isWholeHost(site) == whole)
    }

    /// The frozen list ships in the package, so lookups need no network.
    @Test func usesTheFrozenListOffline() {
        #expect(domain("https://sub.example.com.au") == "example.com.au")
        #expect(domain("https://a.b.example.com.au") == domain("https://c.example.com.au"))
    }
}
