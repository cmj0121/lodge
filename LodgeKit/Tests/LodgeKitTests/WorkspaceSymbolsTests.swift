import Testing

@testable import LodgeKit

@Suite struct WorkspaceSymbolsTests {
    @Test func listHoldsThirtyToFortySymbols() {
        #expect((30...40).contains(WorkspaceSymbols.all.count))
    }

    @Test func namesAreUnique() {
        #expect(Set(WorkspaceSymbols.all).count == WorkspaceSymbols.all.count)
    }

    @Test func containsTheDefaultWorkspaceSymbol() {
        #expect(WorkspaceSymbols.all.contains("square.stack.3d.up"))
    }

    @Test func defaultForNewIsInTheList() {
        #expect(WorkspaceSymbols.all.contains(WorkspaceSymbols.defaultForNew))
    }
}
