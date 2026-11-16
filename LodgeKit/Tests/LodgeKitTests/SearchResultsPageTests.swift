import Foundation
import Testing

@testable import LodgeKit

@Suite struct SearchResultsPageTests {
    private static let added = SearchEngine(
        id: UUID().uuidString, name: "Mine", template: "https://find.example/s?lang=en&term=%s")

    private func match(_ address: String, _ engines: [SearchEngine] = SearchEngine.builtIns + [added])
        -> (engine: SearchEngine, words: String)?
    {
        SearchResultsPage.match(URL(string: address)!, engines: engines)
    }

    @Test(arguments: zip(SearchEngine.builtIns + [added], [
        "https://duckduckgo.com/?q=swift+concurrency&ia=web",
        "https://www.google.com/search?q=swift+concurrency&sca_esv=1",
        "https://www.bing.com/search?form=QBLH&q=swift%20concurrency",
        "https://kagi.com/search?q=swift+concurrency",
        "https://search.brave.com/search?q=swift+concurrency&source=web",
        "https://www.startpage.com/sp/search?query=swift+concurrency",
        "https://find.example/s?term=swift+concurrency",
    ]))
    func everyEngineMatchesItsResultsPage(_ engine: SearchEngine, _ address: String) throws {
        let found = try #require(match(address))
        #expect(found.engine == engine)
        #expect(found.words == "swift concurrency")
    }

    @Test func wordsAreDecoded() {
        #expect(match("https://duckduckgo.com/?q=a+b%20c")?.words == "a b c")
        #expect(match("https://duckduckgo.com/?q=%E5%8F%B0%E5%8C%97+%E5%A4%A9%E6%B0%A3")?.words == "台北 天氣")
        #expect(match("https://duckduckgo.com/?q=%2B1%26more")?.words == "+1&more")
        #expect(match("https://duckduckgo.com/?q=+++padded%20%20")?.words == "padded")
        #expect(match("https://DuckDuckGo.COM/?q=swift")?.words == "swift")
    }

    @Test func aSearchMadeByTheEngineIsReadBack() {
        let words = "what is 1+1 & why?"
        for engine in SearchEngine.builtIns {
            #expect(SearchResultsPage.match(engine.url(for: words)!, engines: [engine])?.words == words)
        }
    }

    @Test func redirectsAndOtherPathsAreNoResultsPages() {
        #expect(match("https://www.google.com/url?q=https://example.com") == nil)
        #expect(match("https://www.google.com/search/about?q=swift") == nil)
        #expect(match("https://www.google.com/search?tbm=isch") == nil)
        #expect(match("https://duckduckgo.com/about?q=swift") == nil)
        #expect(match("https://duckduckgo.com?q=swift") == nil)
        #expect(match("https://www.startpage.com/sp/search?q=swift") == nil)
    }

    @Test func lookAlikeHostsAreNoResultsPages() {
        #expect(match("https://duckduckgo.com.evil.example/?q=swift") == nil)
        #expect(match("https://evilduckduckgo.com/?q=swift") == nil)
        #expect(match("https://google.com/search?q=swift") == nil)
        #expect(match("https://www.google.com:8443/search?q=swift") == nil)
        #expect(match("https://user@evil.example/?q=swift") == nil)
    }

    @Test func otherSchemesAreNoResultsPages() {
        #expect(match("http://duckduckgo.com/?q=swift") == nil)
        #expect(match("ftp://duckduckgo.com/?q=swift") == nil)
    }

    @Test func anEmptyValueIsNoResultsPage() {
        #expect(match("https://duckduckgo.com/?q=") == nil)
        #expect(match("https://duckduckgo.com/?q=+%20+") == nil)
        #expect(match("https://duckduckgo.com/?q") == nil)
        #expect(match("https://duckduckgo.com/") == nil)
    }

    @Test func templatesThatAreNoPlainQueryValueNeverMatch() {
        let http = SearchEngine(id: "h", name: "H", template: "http://plain.example/?q=%s")
        #expect(match("http://plain.example/?q=swift", [http]) == nil)
        #expect(match("https://plain.example/?q=swift", [http]) == nil)
        let inPath = SearchEngine(id: "p", name: "P", template: "https://path.example/search/%s?q=%s")
        #expect(match("https://path.example/search/swift?q=swift", [inPath]) == nil)
        let inHost = SearchEngine(id: "o", name: "O", template: "https://%s.host.example/?q=x")
        #expect(match("https://swift.host.example/?q=x", [inHost]) == nil)
        let partOfValue = SearchEngine(id: "v", name: "V", template: "https://value.example/?q=site:x%s")
        #expect(match("https://value.example/?q=site:xswift", [partOfValue]) == nil)
        let twice = SearchEngine(id: "t", name: "T", template: "https://twice.example/?q=%s&again=%s")
        #expect(match("https://twice.example/?q=swift&again=swift", [twice]) == nil)
    }

    @Test func theFirstMatchingEngineWins() throws {
        let first = SearchEngine(id: "a", name: "A", template: "https://same.example/?q=%s")
        let second = SearchEngine(id: "b", name: "B", template: "https://SAME.example/?q=%s")
        #expect(try #require(match("https://same.example/?q=x", [first, second])).engine == first)
        #expect(try #require(match("https://same.example/?q=x", [second, first])).engine == second)
    }
}
