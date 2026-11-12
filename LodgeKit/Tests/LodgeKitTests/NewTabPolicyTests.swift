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
}
