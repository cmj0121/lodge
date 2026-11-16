import Testing

@testable import LodgeKit

@Suite struct WorkspaceSummaryTests {
    @Test func defaultHasItsSummary() {
        #expect(Workspace.default.summary == "Signed in and remembered")
    }

    @Test func anonymousHasItsSummary() {
        #expect(Workspace.anonymous.summary == "Nothing is kept")
    }

    @Test func customHasNone() {
        #expect(Workspace(name: "Work", symbol: "briefcase").summary == nil)
    }
}
