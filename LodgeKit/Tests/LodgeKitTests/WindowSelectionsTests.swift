import Foundation
import Testing

@testable import LodgeKit

@Suite struct WindowSelectionsTests {
    private let work = UUID()
    private let home = UUID()
    private let w1 = WindowID()
    private let w2 = WindowID()
    private let w3 = WindowID()

    private func tabs(_ workspace: UUID, _ order: [TabID], blank: Set<TabID> = []) -> WorkspaceTabs {
        WorkspaceTabs(workspace: workspace, order: order, blank: blank)
    }

    /// A `newTab` handing out `ids` in turn.
    private func supply(_ ids: [TabID]) -> () -> TabID {
        var queue = ids
        return { queue.removeFirst() }
    }

    /// `windows` on `workspace`, the first key, each showing its tab.
    private func selections(_ workspace: UUID, _ windows: [(WindowID, TabID?)], order: [TabID]) -> WindowSelections {
        var selections = WindowSelections(active: workspace)
        _ = selections.restore(windows.map { (id: $0.0, selectedTab: $0.1) }, fallback: nil, in: tabs(workspace, order))
        return selections
    }

    // MARK: restore

    @Test func restoreGivesEachWindowItsSelectedTab() {
        let t = [TabID(), TabID(), TabID()]
        var selections = WindowSelections(active: Workspace.defaultID)
        let change = selections.restore(
            [(id: w1, selectedTab: t[2]), (id: w2, selectedTab: t[0])], fallback: t[1], in: tabs(work, t))
        #expect(change == SelectionChange())
        #expect(selections.active == work)
        #expect(selections.windows.map(\.id) == [w1, w2])
        #expect(selections.shown(in: w1) == t[2])
        #expect(selections.shown(in: w2) == t[0])
    }

    @Test func restoreFallsBackForTheFirstWindowThenTakesTheFirstFreeTab() {
        let t = [TabID(), TabID(), TabID()]
        var selections = WindowSelections(active: work)
        let change = selections.restore(
            [(id: w1, selectedTab: TabID()), (id: w2, selectedTab: nil), (id: w3, selectedTab: t[1])],
            fallback: t[1], in: tabs(work, t))
        #expect(change == SelectionChange())
        #expect([w1, w2, w3].map(selections.shown(in:)) == [t[0], t[2], t[1]])
    }

    @Test func restoreFallbackTakesWindowZeroOnlyWhenNoWindowSavedIt() {
        let t = [TabID(), TabID(), TabID()]
        var selections = WindowSelections(active: work)
        _ = selections.restore(
            [(id: w1, selectedTab: nil), (id: w2, selectedTab: nil)], fallback: t[2], in: tabs(work, t))
        #expect([w1, w2].map(selections.shown(in:)) == [t[2], t[0]])
    }

    @Test func aLaterWindowsSavedTabIsNotTakenByAnEarlierOnesD3Pick() {
        let t = [TabID(), TabID()]
        var selections = WindowSelections(active: work)
        let change = selections.restore(
            [(id: w1, selectedTab: nil), (id: w2, selectedTab: t[0])], fallback: nil, in: tabs(work, t))
        #expect(change == SelectionChange())
        #expect([w1, w2].map(selections.shown(in:)) == [t[1], t[0]])
    }

    @Test func aLaterWindowsSavedTabIsNotTakenByWindowZerosFallback() {
        let t = [TabID(), TabID()]
        var selections = WindowSelections(active: work)
        _ = selections.restore(
            [(id: w1, selectedTab: nil), (id: w2, selectedTab: t[1])], fallback: t[1], in: tabs(work, t))
        #expect([w1, w2].map(selections.shown(in:)) == [t[0], t[1]])
    }

    @Test func restoreMakesOwnedBlanksWhenTabsRunOut() {
        let t = TabID()
        let blank = TabID()
        var selections = WindowSelections(active: work)
        let change = selections.restore(
            [(id: w1, selectedTab: t), (id: w2, selectedTab: t)], fallback: nil, in: tabs(work, [t]),
            newTab: supply([blank]))
        #expect(change == SelectionChange(create: [blank]))
        #expect(selections.shown(in: w2) == blank)
        #expect(selections.windows.map(\.ownedBlanks) == [[], [blank]])
    }

    @Test func restoreOnAnonymousGivesEachWindowABlank() {
        let blanks = [TabID(), TabID()]
        var selections = WindowSelections(active: Workspace.defaultID)
        let change = selections.restore(
            [(id: w1, selectedTab: nil), (id: w2, selectedTab: nil)], fallback: nil,
            in: tabs(Workspace.anonymousID, []), newTab: supply(blanks))
        #expect(change.create == blanks)
        #expect(selections.active == Workspace.anonymousID)
        #expect(selections.shownTabs == Set(blanks))
    }

    // MARK: windows

    @Test func aNewWindowComesFirstShowingANewOwnedBlank() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let blank = TabID()
        let change = selections.addWindow(w2, newTab: supply([blank]))
        #expect(change == SelectionChange(create: [blank]))
        #expect(selections.windows.map(\.id) == [w2, w1])
        #expect(selections.shown(in: w2) == blank)
        #expect(selections.windows[0].ownedBlanks == [blank])
        #expect(selections.window(showing: blank) == w2)
        #expect(selections.shownTabs == [t, blank])
    }

    @Test func closingAWindowClosesItsOwnedBlankStillBlank() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let blank = TabID()
        _ = selections.addWindow(w2, newTab: supply([blank]))
        let change = selections.removeWindow(w2, in: tabs(work, [t, blank], blank: [blank]))
        #expect(change == SelectionChange(close: [blank]))
        #expect(selections.windows.map(\.id) == [w1])
    }

    @Test func closingAWindowKeepsAnOwnedBlankThatLoaded() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let blank = TabID()
        _ = selections.addWindow(w2, newTab: supply([blank]))
        #expect(selections.removeWindow(w2, in: tabs(work, [t, blank])) == SelectionChange())
    }

    @Test func closingAWindowKeepsItsOwnedBlankWhenAnotherWindowShowsIt() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let blank = TabID()
        _ = selections.addWindow(w2, newTab: supply([blank]))
        let all = tabs(work, [t, blank], blank: [blank])
        let spare = TabID()
        selections.opened(spare, in: work, window: w2)
        #expect(selections.select(blank, in: w1, of: tabs(work, [t, blank, spare], blank: [blank])) == .selected)
        #expect(selections.removeWindow(w2, in: all) == SelectionChange())
        #expect(selections.shown(in: w1) == blank)
    }

    @Test func removingAnUnknownWindowChangesNothing() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let before = selections
        #expect(selections.removeWindow(w2, in: tabs(work, [t])) == SelectionChange())
        #expect(selections == before)
    }

    @Test func makeKeyMovesTheWindowFirst() {
        let t = [TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, t[0]), (w2, t[1]), (w3, t[2])], order: t)
        selections.makeKey(w3)
        #expect(selections.windows.map(\.id) == [w3, w1, w2])
        #expect(selections.remembered(in: work) == t[2])
        selections.makeKey(WindowID())
        #expect(selections.windows.map(\.id) == [w3, w1, w2])
    }

    // MARK: enter

    @Test func enteringTakesEachWindowsRememberedTabBack() {
        let a = [TabID(), TabID()]
        let b = [TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, a[0]), (w2, a[1])], order: a)
        #expect(selections.enter(tabs(home, b), leaving: tabs(work, a)) == SelectionChange())
        #expect(selections.active == home)
        #expect([w1, w2].map(selections.shown(in:)) == [b[0], b[1]])
        _ = selections.select(b[2], in: w1, of: tabs(home, b))
        _ = selections.enter(tabs(work, a), leaving: tabs(home, b))
        #expect([w1, w2].map(selections.shown(in:)) == [a[0], a[1]])
        _ = selections.enter(tabs(home, b), leaving: tabs(work, a))
        #expect([w1, w2].map(selections.shown(in:)) == [b[2], b[1]])
        #expect(selections.remembered(in: work) == a[0])
    }

    @Test func aRememberedTabTakenByTheKeyWindowSendsTheOtherToTheFirstFree() {
        let a = [TabID(), TabID()]
        let b = [TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, a[0]), (w2, a[1])], order: a)
        _ = selections.enter(tabs(home, b), leaving: tabs(work, a))
        selections.opened(b[2], in: work, window: w1)
        selections.opened(b[2], in: work, window: w2)
        _ = selections.enter(tabs(work, a + [b[2]]), leaving: tabs(home, b))
        #expect([w1, w2].map(selections.shown(in:)) == [b[2], a[0]])
    }

    @Test func enteringAWorkspaceWithTooFewTabsMakesOwnedBlanks() {
        let a = [TabID(), TabID()]
        let b = TabID()
        let blank = TabID()
        var selections = selections(work, [(w1, a[0]), (w2, a[1])], order: a)
        let change = selections.enter(tabs(home, [b]), leaving: tabs(work, a), newTab: supply([blank]))
        #expect(change == SelectionChange(create: [blank]))
        #expect([w1, w2].map(selections.shown(in:)) == [b, blank])
        #expect(selections.windows.map(\.ownedBlanks) == [[], [blank]])
    }

    @Test func leavingClosesOwnedBlanksStillBlankOnly() {
        let a = [TabID(), TabID(), TabID()]
        let blanks = [TabID(), TabID()]
        let homeTab = TabID()
        var selections = selections(home, [(w1, homeTab)], order: [homeTab])
        _ = selections.addWindow(w2, newTab: supply([blanks[0]]))
        _ = selections.addWindow(w3, newTab: supply([blanks[1]]))
        let homeTabs = tabs(home, [homeTab, blanks[0], blanks[1]], blank: [blanks[1]])
        let change = selections.enter(tabs(work, a), leaving: homeTabs, newTab: supply([TabID()]))
        #expect(change.close == [blanks[1]])
        #expect(selections.windows.allSatisfy { $0.ownedBlanks.isEmpty })
        #expect(selections.windows.allSatisfy { $0.remembered[home] != blanks[1] })
        #expect(selections.windows.first { $0.id == w2 }?.remembered[home] == blanks[0])
    }

    @Test func aBlankTheWindowDidNotMakeStaysOnLeave() {
        let blank = TabID()
        let other = TabID()
        var selections = selections(work, [(w1, blank)], order: [blank])
        let change = selections.enter(tabs(home, [other]), leaving: tabs(work, [blank], blank: [blank]))
        #expect(change == SelectionChange())
    }

    @Test func enteringTheActiveWorkspaceChangesNothing() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let before = selections
        #expect(selections.enter(tabs(work, [t]), leaving: tabs(work, [t])) == SelectionChange())
        #expect(selections == before)
    }

    @Test func deletingTheActiveWorkspaceTakesEveryWindowToDefault() {
        let a = [TabID(), TabID()]
        let d = TabID()
        let blank = TabID()
        var selections = selections(Workspace.defaultID, [(w1, d)], order: [d])
        _ = selections.enter(tabs(work, a), leaving: tabs(Workspace.defaultID, [d]))
        _ = selections.addWindow(w2, newTab: supply([TabID()]))
        let change = selections.enter(
            tabs(Workspace.defaultID, [d]), leaving: tabs(work, a), newTab: supply([blank]))
        selections.forget(workspace: work)
        #expect(selections.active == Workspace.defaultID)
        #expect(change.create == [blank])
        #expect(Set([w1, w2].compactMap(selections.shown(in:))) == [d, blank])
        #expect(selections.remembered(in: work) == nil)
        #expect(selections.windows.allSatisfy { $0.remembered[work] == nil })
    }

    @Test func forgetDropsADormantWorkspacesMemory() {
        let a = TabID()
        let b = TabID()
        var selections = selections(work, [(w1, a)], order: [a])
        _ = selections.enter(tabs(home, [b]), leaving: tabs(work, [a]))
        #expect(selections.remembered(in: work) == a)
        selections.forget(workspace: work)
        #expect(selections.remembered(in: work) == nil)
        #expect(selections.shown(in: w1) == b)
    }

    // MARK: select and open

    @Test func selectShowsAFreeTab() {
        let t = [TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, t[0]), (w2, t[1])], order: t)
        #expect(selections.select(t[2], in: w1, of: tabs(work, t)) == .selected)
        #expect(selections.shown(in: w1) == t[2])
        #expect(selections.select(t[2], in: w1, of: tabs(work, t)) == .selected)
    }

    @Test func selectingATabAnotherWindowShowsLeavesTheSelection() {
        let t = [TabID(), TabID()]
        var selections = selections(work, [(w1, t[0]), (w2, t[1])], order: t)
        #expect(selections.select(t[1], in: w1, of: tabs(work, t)) == .shownIn(w2))
        #expect(selections.shown(in: w1) == t[0])
        #expect(selections.shown(in: w2) == t[1])
    }

    @Test func selectingAnUnknownTabOrWindowIsUnknown() {
        let t = [TabID(), TabID()]
        var selections = selections(work, [(w1, t[0])], order: t)
        #expect(selections.select(TabID(), in: w1, of: tabs(work, t)) == .unknown)
        #expect(selections.select(t[1], in: w2, of: tabs(work, t)) == .unknown)
        #expect(selections.select(t[1], in: w1, of: tabs(home, t)) == .unknown)
        #expect(selections.shown(in: w1) == t[0])
    }

    @Test func openedShowsTheNewTabInThatWindow() {
        let t = [TabID(), TabID()]
        var selections = selections(work, [(w1, t[0]), (w2, t[1])], order: t)
        let link = TabID()
        selections.opened(link, in: work, window: w2)
        #expect(selections.shown(in: w2) == link)
        #expect(selections.window(showing: t[1]) == nil)
        selections.opened(TabID(), in: work, window: w3)
        #expect(selections.windows.count == 2)
    }

    @Test func aTabReceivedIntoAnotherWorkspaceShowsWhenEnteringIt() {
        let a = TabID()
        let b = [TabID(), TabID()]
        var selections = selections(work, [(w1, a)], order: [a])
        selections.opened(b[1], in: home, window: w1)
        #expect(selections.shown(in: w1) == a)
        #expect(selections.remembered(in: home) == b[1])
        _ = selections.enter(tabs(home, b), leaving: tabs(work, [a]))
        #expect(selections.shown(in: w1) == b[1])
    }

    // MARK: closing

    @Test func closingTheShownTabMovesToTheNextFreeOne() {
        let t = [TabID(), TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, t[1]), (w2, t[2])], order: t)
        #expect(selections.closing([t[1]], in: tabs(work, t)) == SelectionChange())
        #expect(selections.shown(in: w1) == t[3])
        #expect(selections.shown(in: w2) == t[2])
    }

    @Test func closingTheLastShownTabMovesToThePreviousFreeOne() {
        let t = [TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, t[2]), (w2, t[1])], order: t)
        _ = selections.closing([t[2]], in: tabs(work, t))
        #expect(selections.shown(in: w1) == t[0])
    }

    @Test func closingWithNoFreeTabMakesABlankTheWindowDoesNotOwn() {
        let t = [TabID(), TabID()]
        let blank = TabID()
        var selections = selections(work, [(w1, t[0]), (w2, t[1])], order: t)
        let change = selections.closing([t[0]], in: tabs(work, t), newTab: supply([blank]))
        #expect(change == SelectionChange(create: [blank]))
        #expect(selections.shown(in: w1) == blank)
        #expect(selections.windows.allSatisfy { $0.ownedBlanks.isEmpty })
    }

    @Test func closingSeveralShownTabsGivesEachWindowADifferentOne() {
        let t = [TabID(), TabID(), TabID(), TabID()]
        var selections = selections(work, [(w1, t[0]), (w2, t[1])], order: t)
        _ = selections.closing([t[0], t[1]], in: tabs(work, t))
        #expect([w1, w2].map(selections.shown(in:)) == [t[2], t[3]])
    }

    @Test func closingAnOwnedBlankDropsTheOwnership() {
        let t = TabID()
        var selections = selections(work, [(w1, t)], order: [t])
        let blank = TabID()
        _ = selections.addWindow(w2, newTab: supply([blank]))
        _ = selections.closing([blank], in: tabs(work, [t, blank], blank: [blank]), newTab: supply([TabID()]))
        #expect(selections.windows.allSatisfy { $0.ownedBlanks.isEmpty })
    }

    @Test func closingInADormantWorkspaceOnlyPrunesMemory() {
        let a = TabID()
        let b = [TabID(), TabID()]
        var selections = selections(home, [(w1, b[0])], order: b)
        _ = selections.enter(tabs(work, [a]), leaving: tabs(home, b))
        #expect(selections.closing([b[0]], in: tabs(home, b)) == SelectionChange())
        #expect(selections.remembered(in: home) == nil)
        #expect(selections.shown(in: w1) == a)
    }
}
