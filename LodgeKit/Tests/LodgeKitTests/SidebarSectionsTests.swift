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

    @Test func aNavigatedPinKeepsItsRowAndReopensOnItsPinnedURL() {
        var list = TabList()
        let pinTab = BrowserTab(url: URL(string: "https://elsewhere.example")!, link: pin.id)
        list.open(pinTab)
        #expect(SidebarSections(pins: [pin], bookmarks: [], tabs: list).pins == [.link(pin, .pins, pinTab)])
        list.close(pinTab.id, selecting: nil)
        let closed = SidebarSections(pins: [pin], bookmarks: [], tabs: list)
        #expect(closed.pins == [.link(pin, .pins, nil)])
        #expect(closed.pins.first?.target == .link(pin))
    }

    @Test func unpinningLeavesItsOpenTabLoose() {
        var library = LinkLibrary()
        let link = library.add(pin.url, title: pin.title, to: .pins)
        var list = TabList()
        let pinTab = BrowserTab(link: link.id)
        list.open(pinTab)
        library.remove(link.id)
        list.update(pinTab.id) { $0.link = nil }
        let sections = SidebarSections(pins: library.links(on: .pins), bookmarks: [], tabs: list)
        #expect(sections.pins.isEmpty)
        #expect(sections.loose.map(\.tab?.id) == [pinTab.id])
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

    @Test func closingSelectsTheNextEntryWithATabSkippingUnopenedLinks() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let bookmarkTab = BrowserTab(link: bookmark.id)
        let loose = BrowserTab()
        for tab in [loose, bookmarkTab, pinTab] { list.open(tab) }
        let sections = SidebarSections(pins: [pin, unopened], bookmarks: [bookmark], tabs: list)
        #expect(sections.neighbour(ofClosing: pinTab.id) == bookmarkTab.id)
        #expect(sections.neighbour(ofClosing: bookmarkTab.id) == loose.id)
    }

    @Test func closingTheLastEntrySelectsThePreviousOne() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let loose = BrowserTab()
        for tab in [loose, pinTab] { list.open(tab) }
        let sections = SidebarSections(pins: [pin], bookmarks: [unopened], tabs: list)
        #expect(sections.neighbour(ofClosing: loose.id) == pinTab.id)
    }

    @Test func closingTheOnlyOrAnUnknownTabHasNoNeighbour() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [pin], bookmarks: [bookmark], tabs: list)
        #expect(sections.neighbour(ofClosing: loose.id) == nil)
        #expect(sections.neighbour(ofClosing: TabID()) == nil)
    }

    @Test func closeWithTheNeighbourKeepsTheOtherTabsAndSelectsIt() {
        var list = TabList()
        let tabs = [BrowserTab(), BrowserTab(), BrowserTab()]
        for tab in tabs { list.open(tab) }
        list.select(tabs[1].id)
        let next = SidebarSections(pins: [], bookmarks: [], tabs: list).neighbour(ofClosing: tabs[1].id)
        list.close(tabs[1].id, selecting: next)
        #expect(list.tabs == [tabs[0], tabs[2]])
        #expect(list.selectedID == tabs[2].id)
    }
}
