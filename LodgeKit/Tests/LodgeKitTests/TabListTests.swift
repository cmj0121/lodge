import Foundation
import Testing

@testable import LodgeKit

@Suite struct TabListTests {
    private func list(_ count: Int) -> (TabList, [TabID]) {
        var list = TabList()
        let tabs = (0..<count).map { _ in BrowserTab() }
        for tab in tabs { list.open(tab) }
        return (list, tabs.map(\.id))
    }

    @Test func startsEmpty() {
        #expect(TabList().tabs.isEmpty)
    }

    @Test func openAppends() {
        let (list, ids) = list(3)
        #expect(list.tabs.map(\.id) == ids)
    }

    @Test func closeRemovesOnlyTheGivenTab() {
        var (list, ids) = list(3)
        list.close(ids[1])
        #expect(list.tabs.map(\.id) == [ids[0], ids[2]])
    }

    @Test func closingTheLastTabEmptiesTheList() {
        var (list, ids) = list(1)
        list.close(ids[0])
        #expect(list.tabs.isEmpty)
    }

    @Test func closingAnUnknownTabChangesNothing() {
        var (list, _) = list(1)
        let before = list
        list.close(TabID())
        #expect(list == before)
    }

    @Test func restoringKeepsTheTabsInOrder() {
        let tabs = (0..<3).map { _ in BrowserTab(isLive: false) }
        #expect(TabList(tabs: tabs).tabs == tabs)
    }

    @Test func tabsAreLiveUnlessRestored() {
        #expect(BrowserTab().isLive)
        #expect(!BrowserTab(isLive: false).isLive)
    }

    @Test func liveStateIsTrackedPerTab() {
        let tabs = [BrowserTab(isLive: false), BrowserTab(isLive: false)]
        var list = TabList(tabs: tabs)
        list.update(tabs[0].id) { $0.isLive = true }
        #expect(list[tabs[0].id]?.isLive == true)
        #expect(list[tabs[1].id]?.isLive == false)
    }

    @Test func updateChangesOnlyTheGivenTab() throws {
        var (list, ids) = list(2)
        let url = try #require(URL(string: "https://example.com/"))
        list.update(ids[0]) {
            $0.title = "Example"
            $0.url = url
            $0.isLoading = true
        }
        #expect(list[ids[0]]?.title == "Example")
        #expect(list[ids[0]]?.url == url)
        #expect(list[ids[0]]?.isLoading == true)
        #expect(list[ids[1]]?.title == "")
    }

    @Test func newTabsUseTheGlobalStore() {
        #expect(BrowserTab().store == .global)
    }

    @Test func displayTitleFallsBackToTheHostThenToNewTab() throws {
        var tab = BrowserTab()
        #expect(tab.displayTitle == "New Tab")
        tab.url = try #require(URL(string: "https://www.example.com/a"))
        #expect(tab.displayTitle == "www.example.com")
        tab.title = "  "
        #expect(tab.displayTitle == "www.example.com")
        tab.title = "Example"
        #expect(tab.displayTitle == "Example")
    }

    @Test func aLodgePageTabIsTitledAfterItsPage() throws {
        var tab = BrowserTab(url: LodgePage.settings.url, title: "Stale")
        #expect(tab.displayTitle == "Settings")
        tab.url = LodgePage.history.url
        #expect(tab.displayTitle == "History")
        tab.url = try #require(URL(string: "lodge://nowhere"))
        tab.title = ""
        #expect(tab.displayTitle == "nowhere")
    }

    @Test(arguments: [(0, 3, [1, 2, 0, 3]), (3, 0, [3, 0, 1, 2]), (1, nil, [0, 2, 3, 1]), (2, 3, [0, 1, 2, 3])])
    func moveLandsJustBeforeTheGivenTab(moved: Int, before: Int?, order: [Int]) {
        var (list, ids) = list(4)
        list.move(ids[moved], before: before.map { ids[$0] })
        #expect(list.tabs.map(\.id) == order.map { ids[$0] })
    }

    @Test func movingUnknownTabsOrBeforeItselfChangesNothing() {
        var (list, ids) = list(3)
        let before = list
        list.move(TabID(), before: ids[0])
        list.move(ids[0], before: TabID())
        list.move(ids[1], before: ids[1])
        #expect(list == before)
    }
}
