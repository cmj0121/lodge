import Foundation
import Testing

@testable import LodgeKit

@Suite struct SessionSnapshotTests {
    private let pin = SavedLink(url: URL(string: "https://pin.example")!, title: "Pin")
    private let pin2 = SavedLink(url: URL(string: "https://pin2.example")!, title: "Pin 2")
    private let bookmark = SavedLink(url: URL(string: "https://bookmark.example")!, title: "Bookmark")

    private func roundTrip(_ snapshot: SessionSnapshot) throws -> SessionSnapshot {
        try SessionSnapshot.decode(snapshot.encoded())
    }

    @Test func roundTripKeepsTabsSelectionPairingAndLibrary() throws {
        let linked = BrowserTab(url: pin2.url, title: "Pinned page", isLoading: true, canGoBack: true, link: pin2.id)
        let loose = BrowserTab(store: .workspace(UUID()), url: URL(string: "https://loose.example")!, title: "Loose")
        let blank = BrowserTab()
        let marked = BrowserTab(url: bookmark.url, title: "Marked", link: bookmark.id)
        let tabs = TabList(tabs: [linked, loose, blank, marked], selectedID: loose.id)
        let library = LinkLibrary(pins: [pin, pin2], bookmarks: [bookmark])

        let snapshot = SessionSnapshot(tabs: tabs, library: library)
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.version == SessionSnapshot.currentVersion)

        let restored = decoded.restored()
        #expect(restored.tabs.tabs.map(\.id) == [linked.id, loose.id, blank.id, marked.id])
        #expect(restored.tabs.selectedID == loose.id)
        #expect(restored.tabs.tabs.map(\.link) == [pin2.id, nil, nil, bookmark.id])
        #expect(restored.tabs.tab(forLink: pin2.id)?.id == linked.id)
        #expect(restored.tabs.tab(forLink: bookmark.id)?.id == marked.id)
        #expect(restored.tabs.tabs.map(\.url) == [pin2.url, loose.url, nil, bookmark.url])
        #expect(restored.tabs.tabs.map(\.title) == ["Pinned page", "Loose", "", "Marked"])
        #expect(restored.tabs.tabs.map(\.store) == [.global, loose.store, .global, .global])
        #expect(restored.library == library)
        #expect(restored.library.links(on: .pins).map(\.id) == [pin.id, pin2.id])
    }

    @Test func restoredTabsAreNotLiveAndCarryNoRuntimeState() {
        let tab = BrowserTab(
            url: pin.url, isLoading: true, canGoBack: true, canGoForward: true, hasCrashed: true, isLive: true)
        let restored = SessionSnapshot(tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary())
            .restored().tabs.tabs
        #expect(restored.map(\.isLive) == [false])
        #expect(restored.map(\.isLoading) == [false])
        #expect(restored.map(\.canGoBack) == [false])
        #expect(restored.map(\.canGoForward) == [false])
        #expect(restored.map(\.hasCrashed) == [false])
    }

    @Test func dropsALinkNamingNoSavedLink() {
        let tab = BrowserTab(url: pin.url, link: UUID())
        let restored = SessionSnapshot(tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary(pins: [pin]))
            .restored()
        #expect(restored.tabs.tabs.map(\.link) == [nil])
        #expect(restored.tabs.tabs.map(\.url) == [pin.url])
    }

    @Test(arguments: [TabID?.none, TabID()])
    func unknownSelectionFallsToTheFirstTab(selected: TabID?) {
        let first = BrowserTab()
        var snapshot = SessionSnapshot(
            tabs: TabList(tabs: [first, BrowserTab()], selectedID: nil), library: LinkLibrary())
        snapshot.selectedTab = selected
        #expect(snapshot.restored().tabs.selectedID == first.id)
    }

    @Test func emptyTabsRestoreAnEmptyList() throws {
        let snapshot = try roundTrip(SessionSnapshot(tabs: TabList(), library: LinkLibrary(bookmarks: [bookmark])))
        let restored = snapshot.restored()
        #expect(restored.tabs == TabList())
        #expect(restored.library.links(on: .bookmarks) == [bookmark])
    }

    @Test func rejectsANewerVersion() throws {
        var snapshot = SessionSnapshot(tabs: TabList(), library: LinkLibrary())
        snapshot.version = SessionSnapshot.currentVersion + 1
        let data = try snapshot.encoded()
        #expect(throws: SessionSnapshot.DecodeError.unsupportedVersion(SessionSnapshot.currentVersion + 1)) {
            try SessionSnapshot.decode(data)
        }
    }

    @Test(arguments: ["", "{", "not json", #"{"version": 1}"#, #"{"version": "one"}"#])
    func rejectsCorruptJSON(text: String) {
        #expect(throws: DecodingError.self) { try SessionSnapshot.decode(Data(text.utf8)) }
    }
}
