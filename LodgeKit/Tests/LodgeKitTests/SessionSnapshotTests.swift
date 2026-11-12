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
        #expect(LinkShelf.allCases.allSatisfy { restored.library.links(on: $0) == library.links(on: $0) })
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
        let snapshot = try roundTrip(SessionSnapshot(tabs: TabList(), library: LinkLibrary(pins: [], bookmarks: [bookmark])))
        let restored = snapshot.restored()
        #expect(restored.tabs == TabList())
        #expect(restored.library.links(on: .bookmarks) == [bookmark])
    }

    /// Root (expanded) → [bookmark, Work (expanded) → [Docs (closed) → [nested], work], Empty (closed)].
    private func tree() -> (root: BookmarkFolder, nested: SavedLink) {
        let nested = SavedLink(url: URL(string: "https://nested.example")!, title: "Nested")
        let work = SavedLink(url: URL(string: "https://work.example")!, title: "Work page")
        let docs = BookmarkFolder(title: "Docs", children: [.link(nested)])
        let workFolder = BookmarkFolder(title: "Work", isExpanded: true, children: [.folder(docs), .link(work)])
        let root = BookmarkFolder(
            title: "Bookmarks", isExpanded: true,
            children: [.link(bookmark), .folder(workFolder), .folder(BookmarkFolder(title: "Empty"))])
        return (root, nested)
    }

    @Test func roundTripKeepsTheBookmarkTree() throws {
        let (root, _) = tree()
        let decoded = try roundTrip(SessionSnapshot(tabs: TabList(), library: LinkLibrary(pins: [pin], bookmarks: root)))
        #expect(decoded.bookmarks == root)
        let restored = decoded.restored().library
        #expect(restored.bookmarks == root)
        #expect(restored.bookmarks.id == root.id)
        #expect(restored.links(on: .pins) == [pin])
    }

    @Test func pairsTabsWithLinksNestedInFolders() throws {
        let (root, nested) = tree()
        let paired = BrowserTab(url: nested.url, title: "Nested page", link: nested.id)
        let dangling = BrowserTab(url: pin.url, link: UUID())
        let snapshot = SessionSnapshot(
            tabs: TabList(tabs: [paired, dangling], selectedID: paired.id), library: LinkLibrary(bookmarks: root))
        let restored = try roundTrip(snapshot).restored()
        #expect(restored.tabs.tabs.map(\.link) == [nested.id, nil])
        #expect(restored.tabs.tab(forLink: nested.id)?.id == paired.id)
    }

    /// As #3 wrote it: flat bookmarks, `sortedKeys` pretty-printed.
    private static let version1 = """
        {
          "bookmarks" : [
            {
              "id" : "B0000000-0000-0000-0000-000000000001",
              "title" : "First",
              "url" : "https:\\/\\/first.example"
            },
            {
              "id" : "B0000000-0000-0000-0000-000000000002",
              "title" : "Second",
              "url" : "https:\\/\\/second.example"
            }
          ],
          "pins" : [
            {
              "id" : "A0000000-0000-0000-0000-000000000001",
              "title" : "Pin",
              "url" : "https:\\/\\/pin.example"
            }
          ],
          "selectedTab" : "C0000000-0000-0000-0000-000000000002",
          "tabs" : [
            {
              "id" : "C0000000-0000-0000-0000-000000000001",
              "link" : "A0000000-0000-0000-0000-000000000001",
              "store" : {
                "global" : {

                }
              },
              "title" : "Pinned",
              "url" : "https:\\/\\/pin.example"
            },
            {
              "id" : "C0000000-0000-0000-0000-000000000002",
              "link" : "B0000000-0000-0000-0000-000000000002",
              "store" : {
                "workspace" : {
                  "_0" : "D0000000-0000-0000-0000-000000000001"
                }
              },
              "title" : "Second page",
              "url" : "https:\\/\\/second.example"
            }
          ],
          "version" : 1
        }
        """

    @Test func migratesVersion1BookmarksIntoAnExpandedRoot() throws {
        let decoded = try SessionSnapshot.decode(Data(Self.version1.utf8))
        #expect(decoded.version == SessionSnapshot.currentVersion)
        #expect(decoded.bookmarks.isExpanded)
        #expect(decoded.bookmarks.children.map(\.id) == [
            UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
        ])

        let restored = decoded.restored()
        #expect(restored.library.links(on: .bookmarks).map(\.title) == ["First", "Second"])
        #expect(restored.library.links(on: .pins).map(\.url) == [URL(string: "https://pin.example")!])
        #expect(restored.tabs.tabs.map(\.title) == ["Pinned", "Second page"])
        #expect(restored.tabs.tabs.map(\.store) == [
            .global, .workspace(UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!),
        ])
        #expect(restored.tabs.tabs.map(\.link) == [
            UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
        ])
        #expect(restored.tabs.selectedID == UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!)

        let rewritten = try roundTrip(decoded)
        #expect(rewritten == decoded)
        #expect(rewritten.version == 2)
    }

    @Test func rejectsAVersion3File() {
        let data = Data(Self.version1.replacingOccurrences(of: #""version" : 1"#, with: #""version" : 3"#).utf8)
        #expect(throws: SessionSnapshot.DecodeError.unsupportedVersion(3)) { try SessionSnapshot.decode(data) }
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
