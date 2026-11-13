import Foundation
import Testing

@testable import LodgeKit

@Suite struct WorkspaceFormTests {
    private func list(_ names: String...) throws -> WorkspaceList {
        var list = WorkspaceList()
        for name in names { try list.create(name: name, symbol: "star") }
        return list
    }

    private func message(_ name: String, in list: WorkspaceList, renaming id: UUID? = nil) -> String? {
        if case .failure(let error) = list.validate(name: name, renaming: id) {
            return WorkspaceForm.message(for: error, name: name)
        }
        return nil
    }

    @Test func emptyNameAsksForOne() throws {
        #expect(message("   ", in: try list()) == "Enter a name.")
    }

    @Test func longNameStatesTheLimit() throws {
        let list = try list()
        #expect(message(String(repeating: "a", count: 41), in: list) == "Use 40 characters or fewer.")
        #expect(message(String(repeating: "a", count: 40), in: list) == nil)
    }

    @Test func duplicateNameNamesIt() throws {
        #expect(message(" work ", in: try list("Work")) == "A workspace named “work” already exists.")
        #expect(message("default", in: try list()) == "A workspace named “default” already exists.")
        #expect(message("anonymous", in: try list()) == "A workspace named “anonymous” already exists.")
    }

    @Test func fixedWorkspacesExplainThemselves() {
        #expect(WorkspaceForm.message(for: .defaultIsFixed, name: "") == "The Default workspace can’t be renamed.")
        #expect(
            WorkspaceForm.message(for: .anonymousIsFixed, name: "") == "The Anonymous workspace can’t be changed.")
    }

    @Test func renamingKeepsItsOwnName() throws {
        let list = try list("Work")
        #expect(message("WORK", in: list, renaming: list.workspaces[1].id) == nil)
    }

    @Test func arrowsWalkTheGridAndStopAtItsEdges() {
        let move = { (index: Int, move: WorkspaceForm.Move) in
            WorkspaceForm.symbolIndex(from: index, moving: move, columns: 8, count: 20)
        }
        #expect(move(0, .right) == 1)
        #expect(move(0, .left) == 0)
        #expect(move(7, .right) == 7)
        #expect(move(8, .left) == 8)
        #expect(move(3, .up) == 3)
        #expect(move(3, .down) == 11)
        #expect(move(15, .down) == 15)
        #expect(move(19, .right) == 19)
    }

    @Test func everyGridSymbolHasASpokenName() {
        for symbol in WorkspaceSymbols.all {
            #expect(!WorkspaceSymbols.label(for: symbol).contains("."), "\(symbol)")
        }
    }

    @Test func dropTakesTheTargetsPlace() throws {
        let list = try list("A", "B", "C")
        let ids = list.workspaces.map(\.id)
        #expect(list.reorder(dragging: ids[3], onto: ids[1]).map { [$0.from, $0.to] } == [3, 1])
        #expect(list.reorder(dragging: ids[1], onto: ids[3]).map { [$0.from, $0.to] } == [1, 3])
    }

    @Test func dropOntoDefaultLandsAfterIt() throws {
        let list = try list("A", "B")
        let ids = list.workspaces.map(\.id)
        #expect(list.reorder(dragging: ids[2], onto: ids[0]).map { [$0.from, $0.to] } == [2, 1])
        #expect(list.reorder(dragging: ids[1], onto: ids[0]) == nil)
    }

    @Test func dropOntoAnonymousLandsBeforeIt() throws {
        let list = try list("A", "B")
        let ids = list.workspaces.map(\.id)
        #expect(list.reorder(dragging: ids[1], onto: Workspace.anonymousID).map { [$0.from, $0.to] } == [1, 2])
        #expect(list.reorder(dragging: ids[2], onto: Workspace.anonymousID) == nil)
    }

    @Test func defaultAnonymousAndStrangersDoNotMove() throws {
        let list = try list("A")
        let ids = list.workspaces.map(\.id)
        #expect(list.reorder(dragging: ids[0], onto: ids[1]) == nil)
        #expect(list.reorder(dragging: Workspace.anonymousID, onto: ids[1]) == nil)
        #expect(list.reorder(dragging: Workspace.anonymousID, onto: ids[0]) == nil)
        #expect(list.reorder(dragging: UUID(), onto: ids[1]) == nil)
        #expect(list.reorder(dragging: ids[1], onto: UUID()) == nil)
        #expect(list.reorder(dragging: ids[1], onto: ids[1]) == nil)
    }
}
