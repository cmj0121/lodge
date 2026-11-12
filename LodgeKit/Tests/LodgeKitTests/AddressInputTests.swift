import Foundation
import Testing

@testable import LodgeKit

@Suite struct AddressInputTests {
    @Test(arguments: [
        ("https://example.com/path?q=1", "https://example.com/path?q=1"),
        ("http://example.com", "http://example.com"),
        ("  https://example.com  ", "https://example.com"),
        ("about:blank", "about:blank"),
        ("file:///tmp/a.html", "file:///tmp/a.html"),
    ])
    func keepsURLsWithAKnownScheme(input: String, expected: String) {
        #expect(AddressInput.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("www.example.co.uk/a/b?c=d", "https://www.example.co.uk/a/b?c=d"),
        ("example.com:8080/x", "https://example.com:8080/x"),
        ("sub.domain.dev", "https://sub.domain.dev"),
    ])
    func addsHTTPSToBareDomains(input: String, expected: String) {
        #expect(AddressInput.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("localhost", "http://localhost"),
        ("localhost:3000/app", "http://localhost:3000/app"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("[::1]:8080", "http://[::1]:8080"),
    ])
    func addsHTTPToLocalHosts(input: String, expected: String) {
        #expect(AddressInput.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("swift testing", "https://duckduckgo.com/?q=swift%20testing"),
        ("hello", "https://duckduckgo.com/?q=hello"),
        ("what is 1+1?", "https://duckduckgo.com/?q=what%20is%201%2B1%3F"),
        ("a&b=c#d", "https://duckduckgo.com/?q=a%26b%3Dc%23d"),
        ("example.c", "https://duckduckgo.com/?q=example.c"),
        ("v1.2", "https://duckduckgo.com/?q=v1.2"),
        ("1.2.3", "https://duckduckgo.com/?q=1.2.3"),
        ("[1.2.3.4]", "https://duckduckgo.com/?q=%5B1.2.3.4%5D"),
        ("mailto:me@example.com", "https://duckduckgo.com/?q=mailto:me@example.com"),
        ("javascript:alert(1)", "https://duckduckgo.com/?q=javascript:alert(1)"),
        ("中文 搜尋", "https://duckduckgo.com/?q=%E4%B8%AD%E6%96%87%20%E6%90%9C%E5%B0%8B"),
    ])
    func turnsOtherTextIntoASearch(input: String, expected: String) {
        #expect(AddressInput.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func blankInputIsNil(input: String) {
        #expect(AddressInput.url(from: input) == nil)
    }
}
