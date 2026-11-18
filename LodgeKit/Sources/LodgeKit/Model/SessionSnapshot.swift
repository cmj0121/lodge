import Foundation

/// What Lodge keeps across launches: the workspaces in bar order, each with its tabs, selected tab, pins,
/// bookmarks, search settings and fingerprint settings; the windows and the workspace each shows; and the workspaces
/// still being deleted. Anonymous keeps only its bookmarks and search settings, and pins live only in Default. Search
/// words are never stored. Runtime state (loading, history buttons, crashes, progress, favicons, security) is not
/// stored.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 4
    /// Each restored window opens an `NSWindow`, so a corrupt file cannot hang launch with thousands of them.
    public static let maxWindows = 32

    public struct Tab: Codable, Equatable, Sendable {
        public var id: TabID
        /// Nil for a blank tab.
        public var url: URL?
        public var title: String
        public var link: UUID?
    }

    /// One workspace's tabs, pins, bookmarks and search settings.
    public struct WorkspaceContent: Codable, Equatable, Sendable {
        /// In `TabList` order.
        public var tabs: [Tab]
        public var selectedTab: TabID?
        /// In shelf order.
        public var pins: [SavedLink]
        /// The root folder, with every folder's expand state.
        public var bookmarks: BookmarkFolder
        /// Left out of the file when empty, so it stays readable by a v4 build that predates it.
        public var search: WorkspaceSearch

        public static let empty = WorkspaceContent(tabs: TabList(), library: LinkLibrary(), selectedTab: nil)

        /// `selectedTab` is the one an older build restores, and the fallback for the first window (D8).
        public init(tabs: TabList, library: LinkLibrary, selectedTab: TabID?, search: WorkspaceSearch = .empty) {
            self.init(
                tabs: tabs.tabs.map { Tab(id: $0.id, url: $0.url, title: $0.title, link: $0.link) },
                selectedTab: selectedTab, pins: library.links(on: .pins), bookmarks: library.bookmarks,
                search: search)
        }

        init(
            tabs: [Tab], selectedTab: TabID?, pins: [SavedLink], bookmarks: BookmarkFolder,
            search: WorkspaceSearch = .empty
        ) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.pins = pins
            self.bookmarks = bookmarks
            self.search = search
        }

        private enum CodingKeys: String, CodingKey {
            case tabs, selectedTab, pins, bookmarks, search
        }

        /// A missing or malformed `search` reads as `.empty` rather than failing the session file.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tabs = try container.decode([Tab].self, forKey: .tabs)
            selectedTab = try container.decodeIfPresent(TabID.self, forKey: .selectedTab)
            pins = try container.decode([SavedLink].self, forKey: .pins)
            bookmarks = try container.decode(BookmarkFolder.self, forKey: .bookmarks)
            search = (try? container.decodeIfPresent(WorkspaceSearch.self, forKey: .search)) ?? .empty
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tabs, forKey: .tabs)
            try container.encodeIfPresent(selectedTab, forKey: .selectedTab)
            try container.encode(pins, forKey: .pins)
            try container.encode(bookmarks, forKey: .bookmarks)
            if !search.isEmpty { try container.encode(search, forKey: .search) }
        }

        /// Only the bookmarks and search settings: what Anonymous keeps across launches.
        public func anonymized() -> WorkspaceContent {
            WorkspaceContent(tabs: [], selectedTab: nil, pins: [], bookmarks: bookmarks, search: search)
        }

        /// Icons checked: an Anonymous bookmark (`anonymous`) keeps one only when `LinkIcon.isValid`; every other
        /// pin and bookmark keeps none.
        func checkingIcons(anonymous: Bool) -> WorkspaceContent {
            var content = self
            for index in content.pins.indices { content.pins[index].icon = nil }
            content.bookmarks = bookmarks.mappingLinks { link in
                if !anonymous || link.icon.map(LinkIcon.isValid) != true { link.icon = nil }
            }
            return content
        }

        /// Tabs on `store`, isLive false, dangling link dropped; `selectedTab` only when it is one of them. A nil
        /// `store` (Anonymous) gives no tabs and no selection, only the library.
        public func restored(store: StoreRef?) -> (tabs: TabList, library: LinkLibrary, selectedTab: TabID?) {
            let library = LinkLibrary(pins: pins, bookmarks: bookmarks)
            guard let store else { return (TabList(), library, nil) }
            let links = Set((pins + bookmarks.links).map(\.id))
            let restored = tabs.map {
                BrowserTab(
                    id: $0.id, store: store, url: $0.url, title: $0.title,
                    link: $0.link.flatMap { links.contains($0) ? $0 : nil }, isLive: false)
            }
            let selected = restored.contains { $0.id == selectedTab } ? selectedTab : nil
            return (TabList(tabs: restored), library, selected)
        }
    }

    public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
        public var workspace: Workspace
        public var content: WorkspaceContent
        /// Default and custom workspaces always carry one; Anonymous never does, its settings live in memory (D3).
        public var fingerprint: FingerprintSettings?

        /// A nil `fingerprint` gives a non-Anonymous workspace `.fresh()`; Anonymous drops any given (D3).
        public init(workspace: Workspace, content: WorkspaceContent, fingerprint: FingerprintSettings? = nil) {
            self.workspace = workspace
            self.content = content
            self.fingerprint = workspace.kind == .anonymous ? nil : fingerprint ?? .fresh()
        }

        private enum CodingKeys: String, CodingKey {
            case workspace, content, fingerprint
        }

        /// A missing or malformed `fingerprint`, or a key not 32 bytes, reads as `.fresh()`, so an older session
        /// file loads and gains one without a version bump (D3).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                workspace: try container.decode(Workspace.self, forKey: .workspace),
                content: try container.decode(WorkspaceContent.self, forKey: .content),
                fingerprint: try? container.decodeIfPresent(FingerprintSettings.self, forKey: .fingerprint))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(workspace, forKey: .workspace)
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(fingerprint, forKey: .fingerprint)
        }
    }

    /// The optional fields are left out when nil, so a file stays readable by a v4 build that predates them.
    public struct WindowSnapshot: Codable, Equatable, Sendable {
        public var activeWorkspace: UUID
        /// Wins over `WorkspaceContent.selectedTab` at restore.
        public var selectedTab: TabID?
        public var frame: WindowFrame?

        public init(activeWorkspace: UUID, selectedTab: TabID? = nil, frame: WindowFrame? = nil) {
            self.activeWorkspace = activeWorkspace
            self.selectedTab = selectedTab
            self.frame = frame
        }
    }

    public enum DecodeError: Error, Equatable {
        /// Written by a newer Lodge.
        case unsupportedVersion(Int)
    }

    /// `currentVersion` when written.
    public var version: Int
    /// Bar order: Default first, then the custom workspaces, then Anonymous with its bookmarks and search only. Only
    /// Default has pins.
    public var workspaces: [WorkspaceSnapshot]
    /// One to `maxWindows`, all on the same workspace; an unknown active workspace reads as Default.
    public var windows: [WindowSnapshot]
    /// Disjoint from `workspaces`; never Default or Anonymous.
    public var pendingDeletions: [UUID]

    /// Normalizes: Default first, the custom workspaces, Anonymous last (always present, its content
    /// `anonymized()`); duplicate ids, stray `.anonymous` and pending ids dropped. Pins fold into Default: its own
    /// pins in order, then each custom workspace's in bar order unless that URL is already pinned (the first id is
    /// kept); custom workspaces' pins become [] and their tabs linked to one of them lose the link. Pending drops
    /// Default and Anonymous; empty windows → [Default]; unknown active → Default (Anonymous is valid), and every
    /// window takes the first window's. A window keeps its `selectedTab` only when it is a tab of that workspace
    /// and no earlier window kept it, and its `frame` only when finite and at least 1×1. Only Anonymous bookmarks
    /// keep an icon, and only a `LinkIcon.isValid` one. Only the first `maxWindows` windows are kept, cut in file
    /// order before the window rules above, so a window past the cap never takes a `selectedTab`. Each workspace keeps
    /// its fingerprint settings; one missing gets `.fresh()`, and Anonymous has none (D3).
    public init(workspaces: [WorkspaceSnapshot], windows: [WindowSnapshot], pendingDeletions: [UUID]) {
        var seen: Set<UUID> = [Workspace.defaultID, Workspace.anonymousID]
        let pending = pendingDeletions.filter { seen.insert($0).inserted }
        let kept = workspaces.filter {
            ($0.workspace.kind == .anonymous) == ($0.workspace.id == Workspace.anonymousID)
                && !pending.contains($0.workspace.id)
        }
        let list = WorkspaceList(workspaces: kept.map(\.workspace))
        let entries = list.workspaces.map { workspace in kept.first { $0.workspace.id == workspace.id } }
        var contents = entries.map { $0?.content ?? .empty }
        contents[contents.count - 1] = contents[contents.count - 1].anonymized()
        for index in contents.indices.dropFirst().dropLast() {
            let folded = Set(contents[index].pins.map(\.id))
            for pin in contents[index].pins where !contents[0].pins.contains(where: { $0.url == pin.url }) {
                contents[0].pins.append(pin)
            }
            contents[index].pins = []
            for tab in contents[index].tabs.indices where contents[index].tabs[tab].link.map(folded.contains) == true {
                contents[index].tabs[tab].link = nil
            }
        }
        let workspaces = list.workspaces.indices.map { index in
            let workspace = list.workspaces[index]
            return WorkspaceSnapshot(
                workspace: workspace, content: contents[index].checkingIcons(anonymous: workspace.kind == .anonymous),
                fingerprint: entries[index]?.fingerprint)
        }
        let windows = windows.isEmpty
            ? [WindowSnapshot(activeWorkspace: Workspace.defaultID)] : Array(windows.prefix(Self.maxWindows))
        let active = list.resolve(windows[0].activeWorkspace)
        let tabs = Set(workspaces.first { $0.workspace.id == active }?.content.tabs.map(\.id) ?? [])
        var taken: Set<TabID> = []
        version = Self.currentVersion
        self.workspaces = workspaces
        self.windows = windows.map { window in
            WindowSnapshot(
                activeWorkspace: active,
                selectedTab: window.selectedTab.flatMap { tabs.contains($0) && taken.insert($0).inserted ? $0 : nil },
                frame: window.frame.flatMap { $0.isUsable ? $0 : nil })
        }
        self.pendingDeletions = pending
    }

    public var workspaceList: WorkspaceList {
        WorkspaceList(workspaces: workspaces.map(\.workspace))
    }

    public func content(of id: UUID) -> WorkspaceContent? {
        workspaces.first { $0.workspace.id == id }?.content
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspaces, windows, pendingDeletions
    }

    /// Version 1 and 2 keys: one window's tabs, pins and bookmarks.
    private enum LegacyKeys: String, CodingKey {
        case tabs, selectedTab, pins, bookmarks
    }

    /// v1/v2: every tab (any saved store, stray .workspace included), pins, bookmarks fold into Default;
    /// windows = [Default]; pending = []. v1's flat bookmarks become an expanded root folder. v3 and v4: read then
    /// normalized (the pins fold changes only v3). > 4 throws .unsupportedVersion. Always holds `currentVersion`
    /// afterwards.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The version is read first, so a newer file is reported as such rather than as malformed.
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else { throw DecodeError.unsupportedVersion(version) }
        guard version < 3 else {
            self.init(
                workspaces: try container.decode([WorkspaceSnapshot].self, forKey: .workspaces),
                windows: try container.decode([WindowSnapshot].self, forKey: .windows),
                pendingDeletions: try container.decode([UUID].self, forKey: .pendingDeletions))
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let content = WorkspaceContent(
            tabs: try legacy.decode([Tab].self, forKey: .tabs),
            selectedTab: try legacy.decodeIfPresent(TabID.self, forKey: .selectedTab),
            pins: try legacy.decode([SavedLink].self, forKey: .pins),
            bookmarks: version == 1
                ? LinkLibrary(pins: [], bookmarks: try legacy.decode([SavedLink].self, forKey: .bookmarks)).bookmarks
                : try legacy.decode(BookmarkFolder.self, forKey: .bookmarks))
        self.init(
            workspaces: [WorkspaceSnapshot(workspace: .default, content: content)],
            windows: [WindowSnapshot(activeWorkspace: Workspace.defaultID)], pendingDeletions: [])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Throws `SessionSnapshot.DecodeError.unsupportedVersion(Int)` for `version > currentVersion`.
    public static func decode(_ data: Data) throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
