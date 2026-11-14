import Testing

@testable import LodgeKit

@Suite struct WorkspaceColorTests {
    @Test func paletteIsTheEightSwatchesWithoutGraphite() {
        #expect(WorkspaceColor.palette == [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink])
        #expect(!WorkspaceColor.palette.contains(.graphite))
        #expect(WorkspaceColor.allCases == WorkspaceColor.palette + [.graphite])
    }

    @Test func labelsAreSpokenNames() {
        #expect(WorkspaceColor.allCases.map(\.label) == [
            "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink", "Graphite",
        ])
    }

    @Test func rawValuesAreTheStoredNames() {
        #expect(WorkspaceColor.allCases.map(\.rawValue) == [
            "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "graphite",
        ])
    }

    @Test func colorRowWalksNineCellsInOneRow() {
        let count = WorkspaceColor.palette.count + 1
        let move = { (index: Int, step: WorkspaceForm.Move) in
            WorkspaceForm.symbolIndex(from: index, moving: step, columns: count, count: count)
        }
        #expect(move(0, .left) == 0)
        #expect(move(0, .right) == 1)
        #expect(move(8, .right) == 8)
        #expect(move(4, .up) == 4)
        #expect(move(4, .down) == 4)
    }
}
