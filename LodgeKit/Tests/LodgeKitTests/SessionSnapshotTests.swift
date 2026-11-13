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
        #expect(decoded.workspaces.map(\.workspace) == [.default, .anonymous])
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
        #expect(rewritten.version == 4)
    }

    @Test func rejectsAVersion5File() {
        let data = Data(Self.version1.replacingOccurrences(of: #""version" : 1"#, with: #""version" : 5"#).utf8)
        #expect(throws: SessionSnapshot.DecodeError.unsupportedVersion(5)) { try SessionSnapshot.decode(data) }
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
        #expect(decoded.version == 4)
        #expect(decoded.workspaces.map(\.workspace) == [.default, .anonymous])
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
        #expect(rewritten.version == 4)
    }

    // MARK: v3 / v4

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

    @Test func v4RoundTripKeepsWorkspacesWindowsAndPendingDeletions() throws {
        let workTab = BrowserTab(url: URL(string: "https://work.example")!, title: "Work")
        let blank = BrowserTab()
        let homeTab = BrowserTab(url: pin.url, title: "Pin", link: pin.id)
        let pending = UUID()
        let snapshot = SessionSnapshot(
            workspaces: [
                entry(.default, content([BrowserTab()], pins: [pin])),
                entry(work, content([workTab, blank], selected: blank.id)),
                entry(home, content([homeTab])),
            ],
            windows: [window(home.id)], pendingDeletions: [pending])
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.version == 4)
        #expect(decoded.workspaces.map(\.workspace) == [.default, work, home, .anonymous])
        #expect(decoded.windows == [window(home.id)])
        #expect(decoded.pendingDeletions == [pending])
        #expect(decoded.workspaceList.workspaces == [.default, work, home, .anonymous])
        #expect(decoded.content(of: UUID()) == nil)

        let restored = try #require(decoded.content(of: work.id)).restored(store: work.store)
        #expect(restored.tabs.tabs.map(\.id) == [workTab.id, blank.id])
        #expect(restored.tabs.selectedID == blank.id)
        #expect(restored.tabs.tabs.allSatisfy { $0.store == .workspace(work.id) && !$0.isLive })
        let homeRestored = try #require(decoded.content(of: home.id)).restored(store: home.store)
        #expect(homeRestored.tabs.tabs.map(\.link) == [nil])
        #expect(homeRestored.library.links(on: .pins) == [])
        #expect(decoded.content(of: Workspace.defaultID)?.pins == [pin])
    }

    @Test func tabsCarryNoStore() throws {
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
        #expect(Workspace(id: id, name: "A", symbol: "a", kind: .anonymous).store == nil)
        #expect(Workspace.anonymous.store == nil)
    }

    @Test func normalizesAMissingDefaultToFirst() {
        let snapshot = SessionSnapshot(workspaces: [entry(work)], windows: [window(work.id)], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work, .anonymous])
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
        #expect(snapshot.workspaces.map(\.workspace) == [restyled, work, .anonymous])
        #expect(snapshot.content(of: Workspace.defaultID)?.tabs.map(\.id) == [tab.id])
    }

    @Test func normalizesDuplicateIdsKeepingTheFirst() {
        var copy = work
        copy.name = "Copy"
        let tab = BrowserTab()
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work, content([tab])), entry(copy, content([BrowserTab()]))],
            windows: [window(work.id)], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work, .anonymous])
        #expect(snapshot.content(of: work.id)?.tabs.map(\.id) == [tab.id])
    }

    @Test func normalizesAwayStrayAnonymousWorkspacesKeepingTheFixedOneLast() {
        let stray = Workspace(name: "Private", symbol: "eye.slash", kind: .anonymous)
        let impostor = Workspace(id: Workspace.anonymousID, name: "Impostor", symbol: "x")
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(stray, content([BrowserTab()])), entry(impostor), entry(work)],
            windows: [window(stray.id)], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work, .anonymous])
        #expect(snapshot.content(of: Workspace.anonymousID) == .empty)
        #expect(snapshot.windows == [window(Workspace.defaultID)])
    }

    @Test func anonymousIsAlwaysPresentAndLast() {
        let snapshot = SessionSnapshot(
            workspaces: [entry(.anonymous), entry(work), entry(.default)], windows: [], pendingDeletions: [])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, work, .anonymous])
        #expect(SessionSnapshot(workspaces: [], windows: [], pendingDeletions: []).workspaces.map(\.workspace)
            == [.default, .anonymous])
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])

    @Test func onlyAnonymousBookmarksKeepAValidIcon() throws {
        let iconned = SavedLink(url: bookmark.url, title: "Iconned", icon: png)
        let notPNG = SavedLink(url: URL(string: "https://gif.example")!, title: "GIF", icon: Data("GIF89a".utf8))
        let large = SavedLink(
            url: URL(string: "https://large.example")!, title: "Large", icon: png + Data(count: LinkIcon.maxBytes))
        let nested = BookmarkFolder(title: "Nested", children: [.link(notPNG), .link(large)])
        let anonymousLibrary = LinkLibrary(
            pins: [], bookmarks: BookmarkFolder(title: "", children: [.link(iconned), .folder(nested)]))
        var iconnedPin = pin
        iconnedPin.icon = png
        let defaultLibrary = LinkLibrary(pins: [iconnedPin], bookmarks: [iconned])
        let workLibrary = LinkLibrary(pins: [], bookmarks: [iconned])
        let snapshot = SessionSnapshot(
            workspaces: [
                entry(.default, .init(tabs: TabList(), library: defaultLibrary)),
                entry(work, .init(tabs: TabList(), library: workLibrary)),
                entry(.anonymous, .init(tabs: TabList(), library: anonymousLibrary)),
            ], windows: [], pendingDeletions: [])
        let decoded = try roundTrip(snapshot)
        let defaultContent = try #require(decoded.content(of: Workspace.defaultID))
        #expect(defaultContent.pins.map(\.icon) == [nil])
        #expect(defaultContent.bookmarks.links.map(\.icon) == [nil])
        #expect(decoded.content(of: work.id)?.bookmarks.links.map(\.icon) == [nil])
        let anonymous = try #require(decoded.content(of: Workspace.anonymousID))
        #expect(anonymous.bookmarks.links.map(\.icon) == [png, nil, nil])
        #expect(anonymous.bookmarks.links.map(\.title) == ["Iconned", "GIF", "Large"])
    }

    @Test func anonymousKeepsOnlyItsBookmarks() throws {
        let tab = BrowserTab(url: bookmark.url, title: "Secret", link: bookmark.id)
        let marked = SavedLink(url: bookmark.url, title: "Marked", icon: png)
        let anonymousContent = SessionSnapshot.WorkspaceContent(
            tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary(pins: [pin], bookmarks: [marked]))
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(.anonymous, anonymousContent)], windows: [], pendingDeletions: [])
        let decoded = try roundTrip(snapshot)
        let content = try #require(decoded.content(of: Workspace.anonymousID))
        #expect(content == anonymousContent.anonymized())
        #expect(content.tabs.isEmpty)
        #expect(content.selectedTab == nil)
        #expect(content.pins.isEmpty)
        #expect(content.bookmarks.links == [marked])
        #expect(decoded.content(of: Workspace.defaultID)?.pins == [])
        let text = try #require(String(data: snapshot.encoded(), encoding: .utf8))
        #expect(!text.contains("Secret"))
        #expect(!text.contains("pin.example"))
    }

    @Test func anonymousActiveWorkspaceIsKept() throws {
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work)], windows: [window(Workspace.anonymousID)],
            pendingDeletions: [])
        #expect(try roundTrip(snapshot).windows == [window(Workspace.anonymousID)])
    }

    @Test func restoredWithoutAStoreGivesNoTabsOnlyTheLibrary() {
        let tab = BrowserTab(url: bookmark.url, link: bookmark.id)
        let content = SessionSnapshot.WorkspaceContent(
            tabs: TabList(tabs: [tab], selectedID: tab.id), library: LinkLibrary(pins: [], bookmarks: [bookmark]))
        let restored = content.restored(store: nil)
        #expect(restored.tabs == TabList())
        #expect(restored.library.links(on: .bookmarks) == [bookmark])
    }

    @Test func pendingDropsDefaultAndAnonymous() {
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work)], windows: [],
            pendingDeletions: [Workspace.anonymousID, work.id, Workspace.defaultID])
        #expect(snapshot.pendingDeletions == [work.id])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, .anonymous])
    }

    @Test func foldsCustomPinsIntoDefaultDedupedByURL() {
        let duplicate = SavedLink(url: pin.url, title: "Pin again")
        let homePin = SavedLink(url: URL(string: "https://home.example")!, title: "Home pin")
        let workTab = BrowserTab(url: duplicate.url, link: duplicate.id)
        let homeTab = BrowserTab(url: homePin.url, link: homePin.id)
        let markedTab = BrowserTab(url: bookmark.url, link: bookmark.id)
        let homeContent = SessionSnapshot.WorkspaceContent(
            tabs: TabList(tabs: [homeTab, markedTab], selectedID: homeTab.id),
            library: LinkLibrary(pins: [homePin, pin2], bookmarks: [bookmark]))
        let snapshot = SessionSnapshot(
            workspaces: [
                entry(.default, content([], pins: [pin])),
                entry(work, content([workTab], pins: [duplicate, pin2])),
                entry(home, homeContent),
            ],
            windows: [], pendingDeletions: [])
        #expect(snapshot.content(of: Workspace.defaultID)?.pins == [pin, pin2, homePin])
        #expect(snapshot.content(of: work.id)?.pins == [])
        #expect(snapshot.content(of: home.id)?.pins == [])
        #expect(snapshot.content(of: work.id)?.tabs.map(\.link) == [nil])
        #expect(snapshot.content(of: home.id)?.tabs.map(\.link) == [nil, bookmark.id])
        #expect(snapshot.content(of: home.id)?.bookmarks.links == [bookmark])
        let again = SessionSnapshot(workspaces: snapshot.workspaces, windows: [], pendingDeletions: [])
        #expect(again == snapshot)
    }

    /// As #5 wrote it: a custom workspace with its own pin, already pinned in Default, and a tab linked to it.
    private static let version3 = """
        {
          "pendingDeletions" : [],
          "version" : 3,
          "windows" : [{ "activeWorkspace" : "D0000000-0000-0000-0000-000000000001" }],
          "workspaces" : [
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000001", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [{ "id" : "A0000000-0000-0000-0000-000000000001", "title" : "Pin", "url" : "https://pin.example" }],
                "tabs" : []
              },
              "workspace" : { "id" : "00000000-0000-0000-0000-000000000000", "kind" : "default", "name" : "Default", "symbol" : "square.stack.3d.up" }
            },
            {
              "content" : {
                "bookmarks" : { "children" : [], "id" : "F0000000-0000-0000-0000-000000000002", "isExpanded" : true, "title" : "Bookmarks" },
                "pins" : [
                  { "id" : "A0000000-0000-0000-0000-000000000002", "title" : "Pin copy", "url" : "https://pin.example" },
                  { "id" : "A0000000-0000-0000-0000-000000000003", "title" : "Work pin", "url" : "https://work.example" }
                ],
                "selectedTab" : "C0000000-0000-0000-0000-000000000001",
                "tabs" : [
                  { "id" : "C0000000-0000-0000-0000-000000000001", "link" : "A0000000-0000-0000-0000-000000000002", "title" : "Pinned", "url" : "https://pin.example" },
                  { "id" : "C0000000-0000-0000-0000-000000000002", "link" : "A0000000-0000-0000-0000-000000000003", "title" : "Work", "url" : "https://work.example" }
                ]
              },
              "workspace" : { "id" : "D0000000-0000-0000-0000-000000000001", "kind" : "custom", "name" : "Work", "symbol" : "briefcase" }
            }
          ]
        }
        """

    @Test func migratesVersion3FoldingCustomPinsIntoDefault() throws {
        let decoded = try SessionSnapshot.decode(Data(Self.version3.utf8))
        let workID = UUID(uuidString: "D0000000-0000-0000-0000-000000000001")!
        #expect(decoded.version == 4)
        #expect(decoded.workspaces.map(\.workspace.id) == [Workspace.defaultID, workID, Workspace.anonymousID])
        #expect(decoded.windows == [window(workID)])
        #expect(decoded.content(of: Workspace.defaultID)?.pins.map(\.id) == [
            UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
        ])
        let work = try #require(decoded.content(of: workID))
        #expect(work.pins.isEmpty)
        #expect(work.tabs.map(\.link) == [nil, nil])
        #expect(work.tabs.map(\.title) == ["Pinned", "Work"])
        #expect(try roundTrip(decoded) == decoded)
    }

    @Test func normalizesPendingIdsOutOfWorkspaces() {
        let snapshot = SessionSnapshot(
            workspaces: [entry(.default), entry(work), entry(home)], windows: [window(work.id)],
            pendingDeletions: [work.id, work.id, Workspace.defaultID])
        #expect(snapshot.workspaces.map(\.workspace) == [.default, home, .anonymous])
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

    @Test func normalizesAFileWhenRead() throws {
        var snapshot = SessionSnapshot(workspaces: [entry(.default), entry(work)], windows: [], pendingDeletions: [])
        snapshot.workspaces.reverse()
        snapshot.windows = [window(UUID())]
        let decoded = try roundTrip(snapshot)
        #expect(decoded.workspaces.map(\.workspace) == [.default, work, .anonymous])
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
