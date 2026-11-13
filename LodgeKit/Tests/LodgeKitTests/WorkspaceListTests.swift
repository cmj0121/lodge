import Foundation
import Testing

@testable import LodgeKit

@Suite struct WorkspaceListTests {
    typealias EditError = WorkspaceList.EditError

    /// Default, then `names` in order.
    private func list(_ names: String...) throws -> (WorkspaceList, [Workspace]) {
        var list = WorkspaceList()
        let created = try names.map { try list.create(name: $0, symbol: "star") }
        return (list, created)
    }

    @Test func startsWithJustDefault() {
        let list = WorkspaceList()
        #expect(list.workspaces == [.default])
        #expect(list.default == .default)
        #expect(Workspace.default.id == UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        #expect(Workspace.default.name == "Default")
        #expect(Workspace.default.symbol == "square.stack.3d.up")
        #expect(Workspace.default.kind == .default)
        #expect(Workspace.default.store == .global)
    }

    @Test func initPutsOneDefaultFirstAndDropsDuplicates() {
        let work = Workspace(name: "Work", symbol: "briefcase")
        let stray = Workspace(name: "Stray", symbol: "x", kind: .default)
        var restyled = Workspace.default
        restyled.symbol = "star"
        let list = WorkspaceList(workspaces: [work, restyled, work, stray, .default])
        #expect(list.workspaces == [restyled, work])
        #expect(WorkspaceList(workspaces: [work]).workspaces == [.default, work])
    }

    @Test func createAppendsACustomWorkspaceWithATrimmedName() throws {
        var list = WorkspaceList()
        let work = try list.create(name: "  Work \n", symbol: "briefcase")
        #expect(work.name == "Work")
        #expect(work.symbol == "briefcase")
        #expect(work.kind == .custom)
        #expect(work.store == .workspace(work.id))
        #expect(list.workspaces == [.default, work])
        #expect(list[work.id] == work)
        #expect(list[UUID()] == nil)
    }

    @Test(arguments: [
        ("", EditError.emptyName), ("   ", .emptyName), ("work", .duplicateName), ("DEFAULT", .duplicateName),
        (String(repeating: "x", count: WorkspaceList.nameLimit + 1), .nameTooLong),
    ])
    func createRejectsABadName(name: String, error: EditError) throws {
        var (list, _) = try list("Work")
        #expect(throws: error) { try list.create(name: name, symbol: "star") }
        #expect(list.workspaces.count == 2)
    }

    @Test func nameLimitIsInclusive() throws {
        var list = WorkspaceList()
        let name = String(repeating: "x", count: WorkspaceList.nameLimit)
        #expect(try list.create(name: name, symbol: "star").name == name)
        #expect(WorkspaceList.nameLimit == 40)
    }

    @Test(arguments: ["", "  "])
    func createRejectsAnEmptySymbol(symbol: String) {
        var list = WorkspaceList()
        #expect(throws: EditError.emptySymbol) { try list.create(name: "Work", symbol: symbol) }
        #expect(list.workspaces == [.default])
    }

    @Test func renameTrimsAndKeepsItsOwnNameFree() throws {
        var (list, created) = try list("Work", "Home")
        try list.rename(created[0].id, to: " WORK ")
        #expect(list[created[0].id]?.name == "WORK")
        #expect(throws: EditError.duplicateName) { try list.rename(created[0].id, to: "home") }
        #expect(throws: EditError.emptyName) { try list.rename(created[0].id, to: "") }
        #expect(list[created[0].id]?.name == "WORK")
    }

    @Test func renameRejectsDefaultAndUnknown() throws {
        var list = WorkspaceList()
        #expect(throws: EditError.defaultIsFixed) { try list.rename(Workspace.defaultID, to: "Main") }
        let id = UUID()
        #expect(throws: EditError.unknown(id)) { try list.rename(id, to: "Main") }
        #expect(list.workspaces == [.default])
    }

    @Test func setSymbolChangesAnyWorkspaceIncludingDefault() throws {
        var (list, created) = try list("Work")
        try list.setSymbol(created[0].id, "house")
        try list.setSymbol(Workspace.defaultID, "globe")
        #expect(list[created[0].id]?.symbol == "house")
        #expect(list.default.symbol == "globe")
        #expect(throws: EditError.emptySymbol) { try list.setSymbol(created[0].id, " ") }
        let id = UUID()
        #expect(throws: EditError.unknown(id)) { try list.setSymbol(id, "star") }
    }

    @Test func moveReordersAfterDefault() throws {
        var (list, created) = try list("A", "B", "C")
        let (a, b, c) = (created[0], created[1], created[2])
        let first = list.move(from: 3, to: 1)
        #expect(first)
        #expect(list.workspaces == [.default, c, a, b])
        let second = list.move(from: 1, to: 3)
        #expect(second)
        #expect(list.workspaces == [.default, a, b, c])
    }

    @Test func moveClampsTheDestination() throws {
        var (list, created) = try list("A", "B", "C")
        let (a, b, c) = (created[0], created[1], created[2])
        let toDefault = list.move(from: 2, to: 0)
        #expect(toDefault)
        #expect(list.workspaces == [.default, b, a, c])
        let pastTheEnd = list.move(from: 1, to: 99)
        #expect(pastTheEnd)
        #expect(list.workspaces == [.default, a, c, b])
    }

    @Test(arguments: [(0, 2), (-1, 1), (4, 1), (2, 2), (1, 0)])
    func moveRefusesDefaultOutOfRangeAndNoChange(source: Int, destination: Int) throws {
        var (list, _) = try list("A", "B", "C")
        let before = list
        let moved = list.move(from: source, to: destination)
        #expect(!moved)
        #expect(list == before)
    }

    @Test func removeDropsTheWorkspaceAndFreesItsName() throws {
        var (list, created) = try list("Work", "Home")
        #expect(try list.remove(created[0].id) == created[0])
        #expect(list.workspaces == [.default, created[1]])
        let again = try list.create(name: "Work", symbol: "star")
        #expect(again.id != created[0].id)
    }

    @Test func removeRejectsDefaultAndUnknown() {
        var list = WorkspaceList()
        #expect(throws: EditError.defaultIsFixed) { try list.remove(Workspace.defaultID) }
        let id = UUID()
        #expect(throws: EditError.unknown(id)) { try list.remove(id) }
        #expect(list.workspaces == [.default])
    }

    @Test func validateReportsWithoutChanging() throws {
        let (list, created) = try list("Work")
        #expect(list.validate(name: " Home ") == .success("Home"))
        #expect(list.validate(name: "work") == .failure(.duplicateName))
        #expect(list.validate(name: "work", renaming: created[0].id) == .success("work"))
        #expect(list.validate(name: "default", renaming: created[0].id) == .failure(.duplicateName))
        #expect(list.validate(name: "\t") == .failure(.emptyName))
    }

    @Test func resolveFallsBackToDefault() throws {
        let (list, created) = try list("Work")
        #expect(list.resolve(created[0].id) == created[0].id)
        #expect(list.resolve(UUID()) == Workspace.defaultID)
        #expect(list.resolve(nil) == Workspace.defaultID)
    }

    @Test func slotsNumberDefaultThenTheNextEightSkippingAnonymous() throws {
        var (list, created) = try list("1", "2", "3", "4", "5", "6", "7", "8", "9")
        let anonymous = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        list = WorkspaceList(workspaces: [.default, created[0], anonymous] + created.dropFirst())
        #expect(list.workspace(forSlot: 1) == .default)
        #expect(list.workspace(forSlot: 2) == created[0])
        #expect(list.workspace(forSlot: 3) == created[1])
        #expect(list.workspace(forSlot: 9) == created[7])
        #expect(list.workspace(forSlot: 10) == nil)
        #expect(list.workspace(forSlot: 0) == nil)
        #expect(list.slot(of: Workspace.defaultID) == 1)
        #expect(list.slot(of: created[1].id) == 3)
        #expect(list.slot(of: created[8].id) == nil)
        #expect(list.slot(of: anonymous.id) == nil)
        #expect(list.slot(of: UUID()) == nil)
        #expect(WorkspaceList().workspace(forSlot: 2) == nil)
    }
}
