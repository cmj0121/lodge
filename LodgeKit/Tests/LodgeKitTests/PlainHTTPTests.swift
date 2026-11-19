import Foundation
import Testing

@testable import LodgeKit

@Suite struct PlainHTTPTests {
    private func warns(_ string: String, allowed: Set<String> = [], exemptsLoopback: Bool = true) -> Bool {
        PlainHTTP.warns(URL(string: string)!, allowed: allowed, exemptsLoopback: exemptsLoopback)
    }

    @Test func plainHTTPToAHostWarns() {
        #expect(warns("http://example.com/a"))
        #expect(warns("http://10.0.0.1:8080/"))
        #expect(warns("HTTP://Example.COM/"))
    }

    @Test(arguments: ["https://example.com/", "about:blank", "data:text/html,hi", "file:///tmp/a.html", "lodge://settings"])
    func otherSchemesDoNotWarn(url: String) {
        #expect(!warns(url))
    }

    @Test(arguments: ["http://localhost:8080/", "http://127.0.0.1/", "http://127.4.5.6:3000/", "http://[::1]:8000/"])
    func loopbackIsExemptUnlessTurnedOff(url: String) {
        #expect(!warns(url))
        #expect(warns(url, exemptsLoopback: false))
    }

    @Test func anAllowedHostDoesNotWarnOnAnyPortOrPath() {
        #expect(!warns("http://example.com:8080/b?c", allowed: ["example.com"]))
        #expect(!warns("http://EXAMPLE.com/", allowed: ["example.com"]))
        #expect(warns("http://www.example.com/", allowed: ["example.com"]))
    }

    @Test func theHostIsLowercasedWithoutPortOrBrackets() {
        #expect(PlainHTTP.host(of: URL(string: "http://Example.com:81/x")!) == "example.com")
        #expect(PlainHTTP.host(of: URL(string: "http://[::1]:8000/")!) == "::1")
        #expect(PlainHTTP.host(of: URL(string: "https://example.com/")!) == nil)
        #expect(PlainHTTP.host(of: URL(string: "http:///path")!) == nil)
    }
}
