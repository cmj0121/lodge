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

        let snapshot = SessionSnapshot.defaultOnly(tabs: tabs, library: library)
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.version == SessionSnapshot.currentVersion)

        let restored = decoded.defaultRestored()
        #expect(restored.tabs.tabs.map(\.id) == [linked.id, loose.id, blank.id, marked.id])
        #expect(restored.tabs.selectedID == loose.id)
        #expect(restored.tabs.tabs.map(\.link) == [pin2.id, nil, nil, bookmark.id])
        #expect(restored.tabs.tab(forLink: pin2.id)?.id == linked.id)
        #expect(restored.tabs.tab(forLink: bookmark.id)?.id == marked.id)
        #expect(restored.tabs.tabs.map(\.url) == [pin2.url, loose.url, nil, bookmark.url])
        #expect(restored.tabs.tabs.map(\.title) == ["Pinned page", "Loose", "", "Marked"])
        #expect(restored.tabs.tabs.map(\.store) == [.global, .global, .global, .global])
        #expect(LinkShelf.allCases.allSatisfy { restored.library.links(on: $0) == library.links(on: $0) })
        #expect(restored.library.links(on: .pins).map(\.id) == [pin.id, pin2.id])
    }

    @Test func restoredTabsAreNotLiveAndCarryNoRuntimeState() {
        let tab = BrowserTab(
            url: pin.url, isLoading: true, canGoBack: true, canGoForward: true, hasCrashed: true, isLive: true)
        let restored = SessionSnapshot.defaultOnly(tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary())
            .defaultRestored().tabs.tabs
        #expect(restored.map(\.isLive) == [false])
        #expect(restored.map(\.isLoading) == [false])
        #expect(restored.map(\.canGoBack) == [false])
        #expect(restored.map(\.canGoForward) == [false])
        #expect(restored.map(\.hasCrashed) == [false])
    }

    @Test func dropsALinkNamingNoSavedLink() {
        let tab = BrowserTab(url: pin.url, link: UUID())
        let restored = SessionSnapshot.defaultOnly(tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary(pins: [pin]))
            .defaultRestored()
        #expect(restored.tabs.tabs.map(\.link) == [nil])
        #expect(restored.tabs.tabs.map(\.url) == [pin.url])
    }

    @Test(arguments: [TabID?.none, TabID()])
    func unknownSelectionFallsToTheFirstTab(selected: TabID?) {
        let first = BrowserTab()
        var snapshot = SessionSnapshot.defaultOnly(
            tabs: TabList(tabs: [first, BrowserTab()], selectedID: nil), library: LinkLibrary())
        snapshot.workspaces[0].content.selectedTab = selected
        #expect(snapshot.defaultRestored().tabs.selectedID == first.id)
    }

    @Test func emptyTabsRestoreAnEmptyList() throws {
        let snapshot = try roundTrip(SessionSnapshot.defaultOnly(tabs: TabList(), library: LinkLibrary(pins: [], bookmarks: [bookmark])))
        let restored = snapshot.defaultRestored()
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
        let decoded = try roundTrip(SessionSnapshot.defaultOnly(tabs: TabList(), library: LinkLibrary(pins: [pin], bookmarks: root)))
        #expect(decoded.content(of: Workspace.defaultID)?.bookmarks == root)
        let restored = decoded.defaultRestored().library
        #expect(restored.bookmarks == root)
        #expect(restored.bookmarks.id == root.id)
        #expect(restored.links(on: .pins) == [pin])
    }

    @Test func pairsTabsWithLinksNestedInFolders() throws {
        let (root, nested) = tree()
        let paired = BrowserTab(url: nested.url, title: "Nested page", link: nested.id)
        let dangling = BrowserTab(url: pin.url, link: UUID())
        let snapshot = SessionSnapshot.defaultOnly(
            tabs: TabList(tabs: [paired, dangling], selectedID: paired.id), library: LinkLibrary(bookmarks: root))
        let restored = try roundTrip(snapshot).defaultRestored()
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
        #expect(decoded.workspaces.map(\.workspace) == [.default])
        #expect(decoded.windows == [SessionSnapshot.WindowSnapshot(activeWorkspace: Workspace.defaultID)])
        #expect(decoded.pendingDeletions.isEmpty)
        let bookmarks = try #require(decoded.content(of: Workspace.defaultID)?.bookmarks)
        #expect(bookmarks.isExpanded)
        #expect(bookmarks.children.map(\.id) == [
            UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
        ])

        let restored = decoded.defaultRestored()
        #expect(restored.library.links(on: .bookmarks).map(\.title) == ["First", "Second"])
        #expect(restored.library.links(on: .pins).map(\.url) == [URL(string: "https://pin.example")!])
        #expect(restored.tabs.tabs.map(\.title) == ["Pinned", "Second page"])
        #expect(restored.tabs.tabs.map(\.store) == [.global, .global])
        #expect(restored.tabs.tabs.map(\.link) == [
            UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!,
        ])
        #expect(restored.tabs.selectedID == UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!)

        let rewritten = try roundTrip(decoded)
        #expect(rewritten == decoded)
        #expect(rewritten.version == 3)
    }

    @Test func rejectsAVersion4File() {
        let data = Data(Self.version1.replacingOccurrences(of: #""version" : 1"#, with: #""version" : 4"#).utf8)
        #expect(throws: SessionSnapshot.DecodeError.unsupportedVersion(4)) { try SessionSnapshot.decode(data) }
    }

    @Test func rejectsANewerVersion() throws {
        var snapshot = SessionSnapshot.defaultOnly(tabs: TabList(), library: LinkLibrary())
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

    @Test func rejectsAVersion3FileMissingItsWorkspaces() {
        #expect(throws: DecodingError.self) { try SessionSnapshot.decode(Data(#"{"version": 3}"#.utf8)) }
    }

    /// As #4 wrote it: a bookmark tree, and a stray `.workspace` tab nothing before #5 creates.
    private static let version2 = """
        {
          "bookmarks" : {
            "children" : [
              {
                "id" : "B0000000-0000-0000-0000-000000000001",
                "kind" : "link",
                "title" : "Mark",
                "url" : "https:\\/\\/mark.example"
              }
            ],
            "id" : "F0000000-0000-0000-0000-000000000001",
            "isExpanded" : true,
            "title" : "Bookmarks"
          },
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
              "store" : {
                "workspace" : {
                  "_0" : "D0000000-0000-0000-0000-000000000001"
                }
              },
              "title" : "Stray",
              "url" : "https:\\/\\/stray.example"
            }
          ],
          "version" : 2
        }
        """

    @Test func migratesVersion2IntoDefaultIncludingAStrayWorkspaceTab() throws {
        let decoded = try SessionSnapshot.decode(Data(Self.version2.utf8))
        #expect(decoded.version == 3)
        #expect(decoded.workspaces.map(\.workspace) == [.default])
        #expect(decoded.windows == [window(Workspace.defaultID)])
        #expect(decoded.pendingDeletions.isEmpty)

        let restored = decoded.defaultRestored()
        #expect(restored.tabs.tabs.map(\.title) == ["Pinned", "Stray"])
        #expect(restored.tabs.tabs.map(\.store) == [.global, .global])
        #expect(restored.tabs.selectedID == UUID(uuidString: "C0000000-0000-0000-0000-000000000002")!)
        #expect(restored.tabs.tabs.map(\.link) == [UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!, nil])
        #expect(restored.library.links(on: .pins).map(\.title) == ["Pin"])
        #expect(restored.library.links(on: .bookmarks).map(\.title) == ["Mark"])
        #expect(restored.library.bookmarks.id == UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!)

        let rewritten = try roundTrip(decoded)
        #expect(rewritten == decoded)
        #expect(rewritten.version == 3)
    }

    // MARK: v3

    private let work = Workspace(name: "Work", symbol: "briefcase")
    private let home = Workspace(name: "Home", symbol: "house")

    private func content(_ tabs: [BrowserTab], selected: TabID? = nil, pins: [SavedLink] = [])
        -> SessionSnapshot.WorkspaceContent
    {
        SessionSnapshot.WorkspaceContent(
            tabs: TabList(tabs: tabs, selectedID: selected ?? tabs.first?.id), library: LinkLibrary(pins: pins))
    }

    private func entry(_ workspace: Workspace, _ content: SessionSnapshot.WorkspaceContent = .empty)
        -> SessionSnapshot.WorkspaceSnapshot
    {
        SessionSnapshot.WorkspaceSnapshot(workspace: workspace, content: content)
    }

    private func window(_ id: UUID) -> SessionSnapshot.WindowSnapshot { .init(activeWorkspace: id) }

    @Test func v3RoundTripKeepsWorkspacesWindowsAndPendingDeletions() throws {
        let workTab = BrowserTab(url: URL(string: "https://work.example")!, title: "Work")
        let blank = BrowserTab()
        let homeTab = BrowserTab(url: pin.url, title: "Pin", link: pin.id)
        let pending = UUID()
        let snapshot = SessionSnapshot(
            workspaces: [
                entry(.default, content([BrowserTab()])),
                entry(work, content([workTab, blank], selected: blank.id)),
                entry(home, content([homeTab], pins: [pin])),
            ],
            windows: [window(home.id)], pendingDeletions: [pending])
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.version == 3)
        #expect(decoded.workspaces.map(\.workspace) == [.default, work, home])
        #expect(decoded.windows == [window(home.id)])
        #expect(decoded.pendingDeletions == [pending])
        #expect(decoded.workspaceList.workspaces == [.default, work, home])
        #expect(decoded.content(of: UUID()) == nil)

        let restored = try #require(decoded.content(of: work.id)).restored(store: work.store)
        #expect(restored.tabs.tabs.map(\.id) == [workTab.id, blank.id])
        #expect(restored.tabs.selectedID == blank.id)
        #expect(restored.tabs.tabs.allSatisfy { $0.store == .workspace(work.id) && !$0.isLive })
        let homeRestored = try #require(decoded.content(of: home.id)).restored(store: home.store)
        #expect(homeRestored.tabs.tabs.map(\.link) == [pin.id])
        #expect(homeRestored.library.links(on: .pins) == [pin])
    }

    @Test func v3TabsCarryNoStore() throws {
        let snapshot = SessionSnapshot(
            workspaces: [entry(work, content([BrowserTab(store: .workspace(work.id), url: pin.url)]))],
            windows: [window(work.id)], pendingDeletions: [])
        let text = try #require(String(data: snapshot.encoded(), encoding: .utf8))
        #expect(!text.contains("\"store\""))
        #expect(text.contains("\"kind\" : \"custom\""))
    }

    @Test func workspaceStoreFollowsItsKind() {
        let id = UUID()
        #expect(Workspace.default.store == .global)
        #expect(Workspace(id: id, name: "A", symbol: "a").store == .workspace(id))
        #expect(Workspace(id: id, name: "A", symbol: "a", kind: .anonymous).store == .ephemeral(id))
    }

    @Test func normalizesAMissingDefaultToFirst() {
        let snapshot = SessionSnapshot(workspaces: [entry(work)], windows: [window(work.id)], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work])
        #expect(snapshot.content(of: Workspace.defaultID) == .empty)
        #expect(snapshot.windows == [window(work.id)])
    }

    @Test func normalizesDefaultFirstKeepingItsContent() {
        let tab = BrowserTab(url: pin.url)
        var restyled = Workspace.default
        restyled.symbol = "star"
        let snapshot = SessionSnapshot(
            workspaces: [entry(work), entry(restyled, content([tab]))], windows: [window(work.id)],
            pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [restyled, work])
        #expect(snapshot.content(of: Workspace.defaultID)?.tabs.map(\.id) == [tab.id])
    }

    @Test func normalizesDuplicateIdsKeepingTheFirst() {
        var copy = work
        copy.name = "Copy"
        let tab = BrowserTab()
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work, content([tab])), entry(copy, content([BrowserTab()]))],
            windows: [window(work.id)], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work])
        #expect(snapshot.content(of: work.id)?.tabs.map(\.id) == [tab.id])
    }

    @Test func normalizesAwayAnonymousWorkspaces() {
        let anonymous = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(anonymous), entry(work)], windows: [window(anonymous.id)],
            pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work])
        #expect(snapshot.windows == [window(Workspace.defaultID)])
    }

    @Test func normalizesPendingIdsOutOfWorkspaces() {
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work), entry(home)], windows: [window(work.id)],
            pendingDeletions: [work.id, work.id, Workspace.defaultID])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, home])
        #expect(snapshot.pendingDeletions == [work.id])
        #expect(snapshot.windows == [window(Workspace.defaultID)])
    }

    @Test func normalizesEmptyWindowsAndUnknownActive() {
        let none = SessionSnapshot(workspaces: [entry(.default), entry(work)], windows: [], pendingDeletions: [])
        #expect(none.windows == [window(Workspace.defaultID)])
        let unknown = SessionSnapshot(
            workspaces: [entry(.default), entry(work)], windows: [window(UUID()), window(work.id)],
            pendingDeletions: [])
        #expect(unknown.windows == [window(Workspace.defaultID), window(work.id)])
    }

    @Test func normalizesAV3FileWhenRead() throws {
        var snapshot = SessionSnapshot(workspaces: [entry(.default), entry(work)], windows: [], pendingDeletions: [])
        snapshot.workspaces.reverse()
        snapshot.windows = [window(UUID())]
        let decoded = try roundTrip(snapshot)
        #expect(decoded.workspaces.map(\.workspace) == [.default, work])
        #expect(decoded.windows == [window(Workspace.defaultID)])
    }
}

extension SessionSnapshot {
    /// Default alone, holding `tabs` and `library`, in one window on Default.
    static func defaultOnly(tabs: TabList, library: LinkLibrary) -> SessionSnapshot {
        SessionSnapshot(
            workspaces: [WorkspaceSnapshot(workspace: .default, content: WorkspaceContent(tabs: tabs, library: library))],
            windows: [WindowSnapshot(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
    }

    /// Default's content, on `.global`.
    func defaultRestored() -> (tabs: TabList, library: LinkLibrary) {
        (content(of: Workspace.defaultID) ?? .empty).restored(store: .global)
    }
}
