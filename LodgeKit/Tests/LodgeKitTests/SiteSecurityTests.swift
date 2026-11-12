import Foundation
import Testing

@testable import LodgeKit

@Suite struct SiteSecurityTests {
    private func security(_ string: String?, secureContent: Bool = true) -> SiteSecurity {
        SiteSecurity(url: string.flatMap { URL(string: $0) }, hasOnlySecureContent: secureContent)
    }

    @Test func httpsWithOnlySecureContentIsSecure() {
        #expect(security("https://example.com/a") == .secure)
    }

    @Test func httpsWithInsecureContentIsMixed() {
        #expect(security("https://example.com", secureContent: false) == .mixed)
    }

    @Test func httpIsInsecure() {
        #expect(security("http://example.com") == .insecure)
        #expect(security("http://10.0.0.1") == .insecure)
    }

    @Test(arguments: [
        "file:///Users/me/index.html", "http://localhost:8080", "https://localhost", "http://127.0.0.1",
        "http://127.4.5.6:3000", "http://[::1]:8000",
    ])
    func fileAndLoopbackAreLocal(url: String) {
        #expect(security(url, secureContent: false) == .local)
    }

    @Test(arguments: ["about:blank", "data:text/plain,hi", nil] as [String?])
    func noPageIsNone(url: String?) {
        #expect(security(url) == SiteSecurity.none)
    }

    @Test func eachStateHasASymbolAndSummary() {
        let states: [SiteSecurity] = [.none, .secure, .mixed, .insecure, .local]
        #expect(states.map(\.symbol) == ["globe", "lock.fill", "lock.trianglebadge.exclamationmark", "lock.open", "doc"])
        #expect(Set(states.map(\.summary)).count == states.count)
    }
}
