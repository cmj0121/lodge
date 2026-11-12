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

    @Test func startsEmptyWithNothingSelected() {
        let list = TabList()
        #expect(list.tabs.isEmpty)
        #expect(list.selectedID == nil)
        #expect(list.selected == nil)
    }

    @Test func openAppendsAndSelects() {
        let (list, ids) = list(3)
        #expect(list.tabs.map(\.id) == ids)
        #expect(list.selectedID == ids[2])
    }

    @Test func selectIgnoresUnknownTabs() {
        var (list, ids) = list(2)
        list.select(TabID())
        #expect(list.selectedID == ids[1])
    }

    @Test func selectKeepsEveryTabOpen() {
        var (list, ids) = list(3)
        list.select(ids[0])
        list.select(ids[1])
        #expect(list.tabs.map(\.id) == ids)
        #expect(list.selectedID == ids[1])
    }

    @Test func closingTheSelectedTabSelectsTheGivenNext() {
        var (list, ids) = list(3)
        list.select(ids[1])
        list.close(ids[1], selecting: ids[0])
        #expect(list.tabs.map(\.id) == [ids[0], ids[2]])
        #expect(list.selectedID == ids[0])
    }

    @Test func closingTheSelectedTabWithANextNotInTheListLeavesNothingSelected() {
        var (list, ids) = list(3)
        list.close(ids[2], selecting: TabID())
        #expect(list.tabs.map(\.id) == [ids[0], ids[1]])
        #expect(list.selectedID == nil)
        list.select(ids[0])
        list.close(ids[0], selecting: ids[0])
        #expect(list.selectedID == nil)
    }

    @Test func closingAnUnselectedTabKeepsTheSelection() {
        var (list, ids) = list(3)
        list.select(ids[0])
        list.close(ids[2], selecting: ids[1])
        #expect(list.tabs.map(\.id) == [ids[0], ids[1]])
        #expect(list.selectedID == ids[0])
    }

    @Test func closingTheLastTabEmptiesTheList() {
        var (list, ids) = list(1)
        list.close(ids[0], selecting: nil)
        #expect(list.tabs.isEmpty)
        #expect(list.selectedID == nil)
    }

    @Test func closingAnUnknownTabChangesNothing() {
        var (list, ids) = list(1)
        let before = list
        list.close(TabID(), selecting: ids[0])
        #expect(list == before)
    }

    @Test func restoringKeepsTheSelectedTabWhenItIsListed() {
        let tabs = (0..<3).map { _ in BrowserTab(isLive: false) }
        let list = TabList(tabs: tabs, selectedID: tabs[1].id)
        #expect(list.tabs == tabs)
        #expect(list.selectedID == tabs[1].id)
    }

    @Test func restoringFallsBackToTheFirstTab() {
        let tabs = (0..<2).map { _ in BrowserTab(isLive: false) }
        #expect(TabList(tabs: tabs, selectedID: TabID()).selectedID == tabs[0].id)
        #expect(TabList(tabs: tabs, selectedID: nil).selectedID == tabs[0].id)
        #expect(TabList(tabs: [], selectedID: TabID()).selectedID == nil)
    }

    @Test func tabsAreLiveUnlessRestored() {
        #expect(BrowserTab().isLive)
        #expect(!BrowserTab(isLive: false).isLive)
    }

    @Test func liveStateIsTrackedPerTab() {
        let tabs = [BrowserTab(isLive: false), BrowserTab(isLive: false)]
        var list = TabList(tabs: tabs, selectedID: tabs[0].id)
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
}
