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
