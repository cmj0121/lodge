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

    @Test func closingTheSelectedTabLeavesNothingSelected() {
        var (list, ids) = list(3)
        list.select(ids[1])
        list.close(ids[1])
        #expect(list.tabs.map(\.id) == [ids[0], ids[2]])
        #expect(list.selectedID == nil)
    }

    @Test func closingAnUnselectedTabKeepsTheSelection() {
        var (list, ids) = list(3)
        list.select(ids[0])
        list.close(ids[2])
        #expect(list.selectedID == ids[0])
    }

    @Test func closingTheOnlyTabLeavesNothingSelected() {
        var (list, ids) = list(1)
        list.close(ids[0])
        #expect(list.tabs.isEmpty)
        #expect(list.selectedID == nil)
    }

    @Test func closingAnUnknownTabChangesNothing() {
        var (list, _) = list(1)
        let before = list
        list.close(TabID())
        #expect(list == before)
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

    @Test func leavingALooseTabRemovesIt() {
        let link = SavedLink(url: URL(string: "https://pin.example")!, title: "Pin")
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        list.leave(to: nil)
        #expect(list.tabs.isEmpty)
        #expect(list.selectedID == nil)
        #expect(SidebarSections(pins: [link], bookmarks: [], tabs: list).loose.isEmpty)
    }

    @Test func leavingALinkTabKeepsItsRowNotOpen() {
        let link = SavedLink(url: URL(string: "https://pin.example")!, title: "Pin")
        var list = TabList()
        let tab = BrowserTab(link: link.id)
        list.open(tab)
        list.leave(to: nil)
        #expect(list.tab(forLink: link.id) == nil)
        let sections = SidebarSections(pins: [link], bookmarks: [], tabs: list)
        #expect(sections.pins == [.link(link, .pins, nil)])
        #expect(sections.loose.isEmpty)
    }

    @Test func leavingToAnotherTabDropsOnlyTheSelectedOne() {
        var (list, ids) = list(3)
        list.select(ids[0])
        list.leave(to: ids[2])
        #expect(list.tabs.map(\.id) == [ids[1], ids[2]])
        #expect(list.selectedID == ids[2])
    }

    @Test func leavingToTheSelectedOrAnUnknownTabChangesNothing() {
        var (list, ids) = list(2)
        let before = list
        list.leave(to: ids[1])
        list.leave(to: TabID())
        #expect(list == before)
    }

    @Test func leavingWithNothingSelectedRemovesNothing() {
        var list = TabList()
        list.leave(to: nil)
        #expect(list.tabs.isEmpty)
        #expect(list.selectedID == nil)
    }
}
