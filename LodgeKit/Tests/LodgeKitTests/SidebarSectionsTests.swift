import Foundation
import Testing

@testable import LodgeKit

@Suite struct SidebarSectionsTests {
    private let pin = SavedLink(url: URL(string: "https://pin.example")!, title: "Pin")
    private let bookmark = SavedLink(url: URL(string: "https://bookmark.example")!, title: "Bookmark")
    private let unopened = SavedLink(url: URL(string: "https://later.example")!, title: "Later")

    @Test func pairsEachLinkWithItsOpenTab() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        list.open(pinTab)
        let sections = SidebarSections(pins: [pin], bookmarks: [bookmark], tabs: list)
        #expect(sections.pins == [.link(pin, .pins, pinTab)])
        #expect(sections.bookmarks == [.link(bookmark, .bookmarks, bookmarkTab)])
        #expect(sections.loose.isEmpty)
    }

    @Test func leavesUnopenedLinksWithoutATabInLinkOrder() {
        var list = TabList()
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        let sections = SidebarSections(pins: [], bookmarks: [unopened, bookmark], tabs: list)
        #expect(sections.bookmarks == [.link(unopened, .bookmarks, nil), .link(bookmark, .bookmarks, bookmarkTab)])
    }

    @Test func putsLooseTabsAndTabsOfRemovedLinksInLooseInTabOrder() {
        var list = TabList()
        let loose = BrowserTab()
        let orphan = BrowserTab(link: UUID())
        let pinTab = BrowserTab(link: pin.id)
        let other = BrowserTab()
        for tab in [loose, pinTab, orphan, other] { list.open(tab) }
        let sections = SidebarSections(pins: [pin], bookmarks: [], tabs: list)
        #expect(sections.loose == [.tab(loose), .tab(orphan), .tab(other)])
    }

    @Test func aSecondTabOfTheSameLinkStaysLoose() {
        var list = TabList()
        let first = BrowserTab(link: bookmark.id)
        let second = BrowserTab(link: bookmark.id)
        list.open(first)
        list.open(second)
        let sections = SidebarSections(pins: [], bookmarks: [bookmark], tabs: list)
        #expect(sections.bookmarks == [.link(bookmark, .bookmarks, first)])
        #expect(sections.loose == [.tab(second)])
    }

    @Test func tabForLinkFindsTheTabOpenedFromIt() {
        var list = TabList()
        let tab = BrowserTab(link: pin.id)
        list.open(BrowserTab())
        list.open(tab)
        #expect(list.tab(forLink: pin.id) == tab)
        #expect(list.tab(forLink: bookmark.id) == nil)
    }

    @Test func stepsThroughRowsInSidebarOrderAndWraps() {
        var list = TabList()
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        let sections = SidebarSections(pins: [pin], bookmarks: [bookmark, unopened], tabs: list)
        #expect(sections.target(1, from: bookmarkTab.id) == .link(unopened))
        #expect(sections.target(-1, from: bookmarkTab.id) == .link(pin))
        #expect(sections.target(2, from: bookmarkTab.id) == .link(pin))
        #expect(sections.target(-2, from: bookmarkTab.id) == .link(unopened))
    }

    @Test func stepsFromALooseTabIntoTheLinks() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [pin], bookmarks: [bookmark], tabs: list)
        #expect(sections.target(1, from: loose.id) == .link(pin))
        #expect(sections.target(-1, from: loose.id) == .link(bookmark))
        #expect(sections.target(1, from: nil) == .link(pin))
        #expect(sections.target(-1, from: nil) == .tab(loose.id))
    }

    @Test func aLoneRowStepsToItself() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [], bookmarks: [], tabs: list)
        #expect(sections.target(1, from: loose.id) == .tab(loose.id))
        #expect(SidebarSections(pins: [], bookmarks: [], tabs: TabList()).target(1, from: nil) == nil)
    }
}
