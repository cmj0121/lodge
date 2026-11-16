import Foundation
import Testing

@testable import LodgeKit

@Suite struct LocationPromptTests {
    private let page = URL(string: "https://example.com/a?b=c")!

    @Test func newTabStartsEmpty() {
        #expect(LocationPrompt.newTab.initialText(for: page) == "")
        #expect(LocationPrompt.newTab.initialText(for: nil) == "")
    }

    @Test func currentStartsWithThePageAddress() {
        #expect(LocationPrompt.current(TabID()).initialText(for: page) == "https://example.com/a?b=c")
    }

    @Test func currentOnAResultsPageStartsWithTheWords() {
        let results = URL(string: "https://duckduckgo.com/?q=swift+concurrency")!
        let current = LocationPrompt.current(TabID())
        #expect(current.initialText(for: results, engines: SearchEngine.builtIns) == "swift concurrency")
        #expect(current.initialText(for: results) == results.absoluteString)
        #expect(current.initialText(for: page, engines: SearchEngine.builtIns) == "https://example.com/a?b=c")
        #expect(LocationPrompt.newTab.initialText(for: results, engines: SearchEngine.builtIns) == "")
    }

    @Test func currentWithoutAPageStartsEmpty() {
        #expect(LocationPrompt.current(TabID()).initialText(for: nil) == "")
    }

    @Test func promptsForDifferentTabsDiffer() {
        let tab = TabID()
        #expect(LocationPrompt.current(tab) == .current(tab))
        #expect(LocationPrompt.current(tab) != .current(TabID()))
        #expect(LocationPrompt.current(tab) != .newTab)
    }
}
