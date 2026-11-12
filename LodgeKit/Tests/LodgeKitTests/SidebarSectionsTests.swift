import Foundation
import Testing

@testable import LodgeKit

@Suite struct SidebarSectionsTests {
    private let pin = SavedLink(url: URL(string: "https://pin.example")!, title: "Pin")
    private let bookmark = SavedLink(url: URL(string: "https://bookmark.example")!, title: "Bookmark")
    private let unopened = SavedLink(url: URL(string: "https://later.example")!, title: "Later")
    private let open = SavedLink(url: URL(string: "https://open.example")!, title: "Open")
    private let shown = SavedLink(url: URL(string: "https://shown.example")!, title: "Shown")
    private let inner = SavedLink(url: URL(string: "https://inner.example")!, title: "Inner")

    private func root(_ links: SavedLink...) -> BookmarkFolder {
        BookmarkFolder(title: "Bookmarks", isExpanded: true, children: links.map(BookmarkNode.link))
    }

    @Test func pairsEachLinkWithItsOpenTab() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        list.open(pinTab)
        let sections = SidebarSections(pins: [pin], bookmarks: root(bookmark), tabs: list)
        #expect(sections.pins == [.link(pin, .pins, pinTab)])
        #expect(sections.bookmarks == [.item(.link(bookmark, .bookmarks, bookmarkTab))])
        #expect(sections.loose.isEmpty)
    }

    @Test func leavesUnopenedLinksWithoutATabInLinkOrder() {
        var list = TabList()
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        let sections = SidebarSections(pins: [], bookmarks: root(unopened, bookmark), tabs: list)
        #expect(
            sections.bookmarks == [
                .item(.link(unopened, .bookmarks, nil)), .item(.link(bookmark, .bookmarks, bookmarkTab)),
            ])
    }

    @Test func putsLooseTabsAndTabsOfRemovedLinksInLooseInTabOrder() {
        var list = TabList()
        let loose = BrowserTab()
        let orphan = BrowserTab(link: UUID())
        let pinTab = BrowserTab(link: pin.id)
        let other = BrowserTab()
        for tab in [loose, pinTab, orphan, other] { list.open(tab) }
        let sections = SidebarSections(pins: [pin], bookmarks: root(), tabs: list)
        #expect(sections.loose == [.tab(loose), .tab(orphan), .tab(other)])
    }

    @Test func aSecondTabOfTheSameLinkStaysLoose() {
        var list = TabList()
        let first = BrowserTab(link: bookmark.id)
        let second = BrowserTab(link: bookmark.id)
        list.open(first)
        list.open(second)
        let sections = SidebarSections(pins: [], bookmarks: root(bookmark), tabs: list)
        #expect(sections.bookmarks == [.item(.link(bookmark, .bookmarks, first))])
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
        #expect(SidebarSections(pins: [pin], bookmarks: root(), tabs: list).pins == [.link(pin, .pins, pinTab)])
        list.close(pinTab.id, selecting: nil)
        let closed = SidebarSections(pins: [pin], bookmarks: root(), tabs: list)
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
        let sections = SidebarSections(pins: library.links(on: .pins), bookmarks: root(), tabs: list)
        #expect(sections.pins.isEmpty)
        #expect(sections.loose.map(\.tab?.id) == [pinTab.id])
    }

    @Test func stepsThroughRowsInSidebarOrderAndWraps() {
        var list = TabList()
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        let sections = SidebarSections(pins: [pin], bookmarks: root(bookmark, unopened), tabs: list)
        #expect(sections.target(1, from: bookmarkTab.id) == .link(unopened))
        #expect(sections.target(-1, from: bookmarkTab.id) == .link(pin))
        #expect(sections.target(2, from: bookmarkTab.id) == .link(pin))
        #expect(sections.target(-2, from: bookmarkTab.id) == .link(unopened))
    }

    @Test func stepsFromALooseTabIntoTheLinks() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [pin], bookmarks: root(bookmark), tabs: list)
        #expect(sections.target(1, from: loose.id) == .link(pin))
        #expect(sections.target(-1, from: loose.id) == .link(bookmark))
        #expect(sections.target(1, from: nil) == .link(pin))
        #expect(sections.target(-1, from: nil) == .tab(loose.id))
    }

    @Test func aLoneRowStepsToItself() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [], bookmarks: root(), tabs: list)
        #expect(sections.target(1, from: loose.id) == .tab(loose.id))
        #expect(SidebarSections(pins: [], bookmarks: root(), tabs: TabList()).target(1, from: nil) == nil)
    }

    @Test func closingSelectsTheNextEntryWithATabSkippingUnopenedLinks() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let bookmarkTab = BrowserTab(link: bookmark.id)
        let loose = BrowserTab()
        for tab in [loose, bookmarkTab, pinTab] { list.open(tab) }
        let sections = SidebarSections(pins: [pin, unopened], bookmarks: root(bookmark), tabs: list)
        #expect(sections.neighbour(ofClosing: pinTab.id) == bookmarkTab.id)
        #expect(sections.neighbour(ofClosing: bookmarkTab.id) == loose.id)
    }

    @Test func closingTheLastEntrySelectsThePreviousOne() {
        var list = TabList()
        let pinTab = BrowserTab(link: pin.id)
        let loose = BrowserTab()
        for tab in [loose, pinTab] { list.open(tab) }
        let sections = SidebarSections(pins: [pin], bookmarks: root(unopened), tabs: list)
        #expect(sections.neighbour(ofClosing: loose.id) == pinTab.id)
    }

    @Test func closingTheOnlyOrAnUnknownTabHasNoNeighbour() {
        var list = TabList()
        let loose = BrowserTab()
        list.open(loose)
        let sections = SidebarSections(pins: [pin], bookmarks: root(bookmark), tabs: list)
        #expect(sections.neighbour(ofClosing: loose.id) == nil)
        #expect(sections.neighbour(ofClosing: TabID()) == nil)
    }

    @Test func closeWithTheNeighbourKeepsTheOtherTabsAndSelectsIt() {
        var list = TabList()
        let tabs = [BrowserTab(), BrowserTab(), BrowserTab()]
        for tab in tabs { list.open(tab) }
        list.select(tabs[1].id)
        let next = SidebarSections(pins: [], bookmarks: root(), tabs: list).neighbour(ofClosing: tabs[1].id)
        list.close(tabs[1].id, selecting: next)
        #expect(list.tabs == [tabs[0], tabs[2]])
        #expect(list.selectedID == tabs[2].id)
    }

    @Test func pairsTabsWithBookmarksInNestedFolders() {
        let inner = BookmarkFolder(title: "Inner", isExpanded: true, children: [.link(bookmark)])
        let outer = BookmarkFolder(title: "Outer", children: [.folder(inner)])
        var list = TabList()
        let bookmarkTab = BrowserTab(link: bookmark.id)
        list.open(bookmarkTab)
        let root = BookmarkFolder(title: "Bookmarks", isExpanded: true, children: [.link(unopened), .folder(outer)])
        let sections = SidebarSections(pins: [], bookmarks: root, tabs: list)
        #expect(
            sections.bookmarks == [
                .item(.link(unopened, .bookmarks, nil)),
                .folder(
                    id: outer.id, title: "Outer", isExpanded: false,
                    children: [
                        .folder(
                            id: inner.id, title: "Inner", isExpanded: true,
                            children: [.item(.link(bookmark, .bookmarks, bookmarkTab))])
                    ]),
            ])
        #expect(sections.bookmarks.map(\.id) == [.link(unopened.id), .folder(outer.id)])
        #expect(sections.loose.isEmpty)
    }

    @Test func deletingAFolderLeavesItsBookmarksOpenTabsLoose() {
        var library = LinkLibrary()
        let folder = library.addFolder("F", in: library.bookmarks.id)!.id
        let link = library.addBookmark(bookmark.url, title: bookmark.title, in: folder)!
        var list = TabList()
        let tab = BrowserTab(link: link.id)
        list.open(tab)
        #expect(SidebarSections(pins: [], bookmarks: library.bookmarks, tabs: list).loose.isEmpty)
        for id in library.remove(folder) {
            if let open = list.tab(forLink: id) { list.update(open.id) { $0.link = nil } }
        }
        let sections = SidebarSections(pins: [], bookmarks: library.bookmarks, tabs: list)
        #expect(sections.bookmarks.isEmpty)
        #expect(sections.loose.map(\.tab?.id) == [tab.id])
    }

    /// Pins: pin. Root: Closed [later, Inner (open) [inner], open], Shown (open) [shown], bookmark.
    private func folders(tabs: [BrowserTab]) -> SidebarSections {
        let closed = BookmarkFolder(
            title: "Closed",
            children: [
                .link(unopened), .folder(BookmarkFolder(title: "Inner", isExpanded: true, children: [.link(inner)])),
                .link(open),
            ])
        let root = BookmarkFolder(
            title: "Bookmarks", isExpanded: true,
            children: [
                .folder(closed), .folder(BookmarkFolder(title: "Shown", isExpanded: true, children: [.link(shown)])),
                .link(bookmark),
            ])
        var list = TabList()
        for tab in tabs { list.open(tab) }
        return SidebarSections(pins: [pin], bookmarks: root, tabs: list)
    }

    @Test func stepsDepthFirstVisitingClosedFoldersOnlyForOpenTabs() {
        let openTab = BrowserTab(link: open.id)
        let sections = folders(tabs: [openTab])
        #expect(sections.target(-1, from: openTab.id) == .link(pin))
        #expect(sections.target(1, from: openTab.id) == .link(shown))
        #expect(sections.target(2, from: openTab.id) == .link(bookmark))
        #expect(sections.target(3, from: openTab.id) == .link(pin))
    }

    @Test func closingStepsThroughOpenTabsInEveryFolder() {
        let pinTab = BrowserTab(link: pin.id)
        let laterTab = BrowserTab(link: unopened.id)
        let bookmarkTab = BrowserTab(link: bookmark.id)
        let loose = BrowserTab()
        let sections = folders(tabs: [loose, bookmarkTab, laterTab, pinTab])
        #expect(sections.neighbour(ofClosing: pinTab.id) == laterTab.id)
        #expect(sections.neighbour(ofClosing: laterTab.id) == bookmarkTab.id)
        #expect(sections.neighbour(ofClosing: bookmarkTab.id) == loose.id)
    }
}
