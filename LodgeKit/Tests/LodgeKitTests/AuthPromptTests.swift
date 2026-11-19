import Foundation
import Testing

@testable import LodgeKit

@Suite struct AuthPromptTests {
    private func space(
        _ host: String = "intranet.example.com", port: Int = 443, scheme: String = NSURLProtectionSpaceHTTPS,
        realm: String? = "Staff", method: String = NSURLAuthenticationMethodHTTPBasic
    ) -> URLProtectionSpace {
        URLProtectionSpace(host: host, port: port, protocol: scheme, realm: realm, authenticationMethod: method)
    }

    private func prompt(
        _ space: URLProtectionSpace, failures: Int = 0, user: String? = nil,
        pageSite: String? = "example.com", navigation: String? = nil
    ) -> AuthPrompt? {
        AuthPrompt(space: space, previousFailureCount: failures, proposedUser: user,
                   pageSite: pageSite, navigation: navigation.flatMap { URL(string: $0) }.map(Origin.init(url:)))
    }

    @Test(arguments: [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM])
    func passwordMethodsPrompt(method: String) {
        #expect(AuthPrompt.prompts(for: method))
        #expect(prompt(space(method: method)) != nil)
    }

    @Test(arguments: [
        NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodClientCertificate,
        NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodDefault, NSURLAuthenticationMethodHTMLForm,
    ])
    func otherMethodsDoNotPrompt(method: String) {
        #expect(!AuthPrompt.prompts(for: method))
        #expect(prompt(space(method: method)) == nil)
    }

    @Test func sameSiteAcrossSubdomainsPrompts() {
        #expect(prompt(space("intranet.example.com"), pageSite: "example.com") != nil)
        #expect(prompt(space("Login.Example.COM"), pageSite: "example.com") != nil)
    }

    /// An image or iframe from another site must not put its own sign-in sheet over this page.
    @Test func otherSiteGetsNoPrompt() {
        #expect(prompt(space("evil.test"), pageSite: "example.com") == nil)
        #expect(prompt(space("evil.test"), pageSite: "example.com", navigation: "https://www.example.com/") == nil)
    }

    @Test func ipAndWholeHostSitesMatchOnlyThemselves() {
        #expect(prompt(space("::1"), pageSite: "::1") != nil)
        #expect(prompt(space("::1"), pageSite: "::2") == nil)
        #expect(prompt(space("1.2.3.4"), pageSite: "1.2.3.5") == nil)
        #expect(prompt(space("bob.github.io"), pageSite: "alice.github.io") == nil)
        #expect(prompt(space("example.com."), pageSite: "example.com") == nil)
    }

    @Test func otherSiteThatIsTheNavigationTargetPrompts() {
        let target = prompt(space("router.local"), pageSite: "example.com", navigation: "https://router.local/admin")
        #expect(target?.isNavigationTarget == true)
        #expect(prompt(space("Router.Local"), pageSite: "example.com", navigation: "https://router.LOCAL/") != nil)
        #expect(prompt(space("router.local", port: 8443), pageSite: "example.com",
                       navigation: "https://router.local:8443/") != nil)
        #expect(prompt(space("router.local", port: 0), pageSite: "example.com", navigation: "https://router.local:443/")
            != nil)
        #expect(prompt(space("::1", port: 8080, scheme: NSURLProtectionSpaceHTTP), pageSite: "example.com",
                       navigation: "http://[::1]:8080/") != nil)
    }

    /// The navigation target is matched by origin: the same host on another scheme or port is another site.
    @Test func navigationTargetMatchesSchemeHostAndPort() {
        let page = "example.com"
        #expect(prompt(space("router.local", port: 8443), pageSite: page, navigation: "https://router.local/") == nil)
        #expect(prompt(space("router.local", port: 80, scheme: NSURLProtectionSpaceHTTP), pageSite: page,
                       navigation: "https://router.local/") == nil)
        #expect(prompt(space("router.local"), pageSite: page, navigation: "http://router.local:443/") == nil)
        #expect(prompt(space("router.local"), pageSite: page, navigation: "https://other.local/") == nil)
    }

    @Test func sameSiteIsNotTheNavigationTarget() {
        #expect(prompt(space("intranet.example.com"), pageSite: "example.com")?.isNavigationTarget == false)
    }

    @Test func noCommittedPageWithANavigationTargetPrompts() {
        #expect(prompt(space("intranet.example.com"), pageSite: nil, navigation: "https://intranet.example.com/")
            != nil)
        #expect(prompt(space("intranet.example.com"), pageSite: nil, navigation: nil) == nil)
    }

    @Test func siteIsTheRegistrableDomain() {
        #expect(prompt(space("Login.Intranet.Example.com"))?.site == "example.com")
        #expect(prompt(space("example.com.evil.net"), pageSite: "evil.net")?.site == "evil.net")
        #expect(prompt(space("1.2.3.4", port: 8443), pageSite: "1.2.3.4")?.site == "1.2.3.4")
        #expect(prompt(space("localhost", port: 8080), pageSite: "localhost")?.site == "localhost")
        #expect(prompt(space("bob.github.io"), pageSite: "bob.github.io")?.site == "bob.github.io")
    }

    @Test func shortHostIsShownWhole() {
        #expect(prompt(space("a.example.com", port: 8443))?.shownHost == "a.example.com:8443")
        let sixty = String(repeating: "a", count: 48) + ".example.com"
        #expect(prompt(space(sixty))?.shownHost == sixty)
    }

    /// A long host keeps its end, the part that names the site, and loses its first labels.
    @Test func longHostIsCutFromTheLeft() {
        let host = "login.bank.com." + String(repeating: "x", count: 60) + ".evil.net"
        let shown = prompt(space(host, port: 8443), pageSite: "evil.net")?.shownHost
        #expect(shown?.count == 60)
        #expect(shown?.hasPrefix("…") == true)
        #expect(shown?.hasSuffix(".evil.net:8443") == true)
        #expect(prompt(space(host, port: 8443), pageSite: "evil.net")?.host == host + ":8443")
    }

    @Test func plainHTTPIsFlagged() {
        #expect(prompt(space(port: 80, scheme: NSURLProtectionSpaceHTTP))?.isPlainHTTP == true)
        #expect(prompt(space())?.isPlainHTTP == false)
    }

    @Test func failedOnlyAfterAPreviousFailure() {
        #expect(prompt(space(), failures: 0)?.failed == false)
        #expect(prompt(space(), failures: 2)?.failed == true)
    }

    @Test func proposedUserIsKept() {
        #expect(prompt(space(), user: "ann")?.proposedUser == "ann")
        #expect(prompt(space())?.proposedUser == nil)
    }

    @Test func portShownOnlyWhenNotTheDefault() {
        #expect(prompt(space("a.example.com", port: 443))?.host == "a.example.com")
        #expect(prompt(space("a.example.com", port: 80, scheme: NSURLProtectionSpaceHTTP))?.host == "a.example.com")
        #expect(prompt(space("a.example.com", port: 8443))?.host == "a.example.com:8443")
        #expect(prompt(space("a.example.com", port: 443, scheme: NSURLProtectionSpaceHTTP))?.host == "a.example.com:443")
        #expect(prompt(space("a.example.com", port: 0))?.host == "a.example.com")
        #expect(prompt(space("fe80::1", port: 8443), pageSite: "fe80::1")?.host == "[fe80::1]:8443")
        #expect(prompt(space("fe80::1", port: 443), pageSite: "fe80::1")?.host == "fe80::1")
    }

    @Test func realmIsTrimmed() {
        #expect(prompt(space(realm: "  Staff area \n"))?.realm == "Staff area")
    }

    @Test func realmLineBreaksBecomeSpaces() {
        #expect(prompt(space(realm: "Staff\narea"))?.realm == "Staff area")
        #expect(prompt(space(realm: "Staff\r\n\tarea"))?.realm == "Staff area")
        #expect(prompt(space(realm: "Staff\u{2028}area\u{2029}two"))?.realm == "Staff area two")
    }

    @Test func realmBidiAndZeroWidthCharactersAreRemoved() {
        #expect(prompt(space(realm: "Staff\u{202E}txt.exe"))?.realm == "Stafftxt.exe")
        #expect(prompt(space(realm: "\u{2066}Sta\u{200B}ff\u{2069}\u{200D}\u{FEFF}"))?.realm == "Staff")
        #expect(prompt(space(realm: "Staff\u{0007}\u{001B}area"))?.realm == "Staffarea")
    }

    @Test func realmWhitespaceRunsCollapse() {
        #expect(prompt(space(realm: "Staff    \u{00A0}\u{3000} area"))?.realm == "Staff area")
    }

    /// Hidden characters and whitespace runs go before the cut, so they cannot push visible text past it.
    @Test func realmIsCleanedBeforeTheCut() {
        let sixty = String(repeating: "r", count: 60)
        #expect(prompt(space(realm: String(repeating: "\u{200B}", count: 50) + sixty))?.realm == sixty)
        #expect(prompt(space(realm: "a" + String(repeating: " ", count: 80) + "b"))?.realm == "a b")
    }

    @Test(arguments: [nil, "", "   \n", "\u{200B}\u{202E}"])
    func emptyRealmIsNil(realm: String?) {
        #expect(prompt(space(realm: realm))?.realm == nil)
    }

    @Test func longRealmIsCutAtSixty() {
        let sixty = String(repeating: "r", count: 60)
        #expect(prompt(space(realm: sixty))?.realm == sixty)
        #expect(prompt(space(realm: sixty + "tail"))?.realm == sixty + "…")
    }
}
