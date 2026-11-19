import Testing

@testable import LodgeKit

@Suite struct SafariUserAgentTests {
    @Test(arguments: ["18.0", "26.1", "17", "18.3.1"])
    func anInstalledSafariVersionIsNamed(version: String) {
        #expect(SafariUserAgent.applicationName(safariVersion: version) == "Version/\(version) Safari/605.1.15")
    }

    @Test(arguments: [nil, "", " ", "18.", ".1", "18..1", "18.0 beta", "v18", "18.0\n", "１８"] as [String?])
    func anythingElseFallsBack(version: String?) {
        #expect(
            SafariUserAgent.applicationName(safariVersion: version)
                == "Version/\(SafariUserAgent.fallbackVersion) Safari/605.1.15")
    }

    @Test func theFallbackIsItselfAVersion() {
        #expect(SafariUserAgent.fallbackVersion.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil)
    }
}
