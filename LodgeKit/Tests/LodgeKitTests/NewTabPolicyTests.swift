import Foundation
import Testing

@testable import LodgeKit

@Suite struct NewTabPolicyTests {
    @Test(arguments: ["https://example.com/a", "http://localhost:3000", "HTTPS://EXAMPLE.COM", "about:blank"])
    func allowsWebURLsAndBlank(url: String) throws {
        #expect(NewTabPolicy.allows(try #require(URL(string: url))))
    }

    @Test(arguments: [
        "data:text/html,<script>alert(1)</script>", "file:///etc/passwd", "javascript:alert(1)",
        "about:srcdoc", "about:config", "blob:https://example.com/uuid", "mailto:me@example.com", "http:/nohost",
    ])
    func refusesOtherSchemes(url: String) throws {
        #expect(!NewTabPolicy.allows(try #require(URL(string: url))))
    }

    @Test func historyOpensOnlyWebPages() throws {
        for url in ["https://example.com/a", "HTTP://localhost:3000"] {
            #expect(NewTabPolicy.allowsFromHistory(try #require(URL(string: url))))
        }
        for url in ["about:blank", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "http:/nohost"] {
            #expect(!NewTabPolicy.allowsFromHistory(try #require(URL(string: url))))
        }
    }
}
