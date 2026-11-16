import Foundation
import Testing

@testable import LodgeKit

@Suite struct LodgePageTests {
    @Test(arguments: [
        ("lodge://settings", LodgePage.settings), ("lodge://history", .history), ("LODGE://SETTINGS", .settings),
        ("Lodge://History/", .history), ("lodge://settings/", .settings),
    ])
    func parsesItsPagesIgnoringCase(text: String, page: LodgePage) throws {
        #expect(LodgePage(url: try #require(URL(string: text))) == page)
    }

    @Test(arguments: [
        "lodge:", "lodge:settings", "lodge://", "lodge://about", "lodge://settings/general", "lodge://settings?x=1",
        "lodge://settings#top", "lodge://user@settings", "lodge://user:pw@settings", "lodge://settings:8080",
        "lodge://settings//", "https://settings", "settings", "about:blank",
    ])
    func refusesEverythingElse(text: String) throws {
        #expect(LodgePage(url: try #require(URL(string: text))) == nil)
    }

    @Test func canonicalURLsAreLowerCaseWithNoTrailingSlash() {
        #expect(LodgePage.settings.url.absoluteString == "lodge://settings")
        #expect(LodgePage.history.url.absoluteString == "lodge://history")
        #expect(LodgePage.allCases.allSatisfy { LodgePage(url: $0.url) == $0 })
    }

    @Test func isLodgeLooksOnlyAtTheScheme() throws {
        for text in ["lodge:", "LODGE://anything", "lodge://settings"] {
            #expect(LodgePage.isLodge(try #require(URL(string: text))))
        }
        for text in ["https://lodge.example", "about:blank", "lodgex://settings"] {
            #expect(!LodgePage.isLodge(try #require(URL(string: text))))
        }
        #expect(!LodgePage.isLodge(nil))
    }

    @Test func titlesAndSymbols() {
        #expect(LodgePage.settings.title == "Settings")
        #expect(LodgePage.history.title == "History")
        #expect(LodgePage.settings.symbol == "gearshape")
        #expect(LodgePage.history.symbol == "clock")
    }

    @Test func titlesAreTranslatedToTraditionalChinese() throws {
        let path = try #require(Bundle.module.path(forResource: "zh-Hant", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Settings", value: nil, table: nil) == "設定")
        #expect(bundle.localizedString(forKey: "History", value: nil, table: nil) == "瀏覽紀錄")
    }

    @Test func aTabKnowsItsPage() throws {
        #expect(BrowserTab(url: LodgePage.history.url).lodgePage == .history)
        #expect(BrowserTab(url: try #require(URL(string: "LODGE://SETTINGS"))).lodgePage == .settings)
        #expect(BrowserTab(url: try #require(URL(string: "lodge://nowhere"))).lodgePage == nil)
        #expect(BrowserTab(url: try #require(URL(string: "https://example.com"))).lodgePage == nil)
        #expect(BrowserTab().lodgePage == nil)
    }
}
