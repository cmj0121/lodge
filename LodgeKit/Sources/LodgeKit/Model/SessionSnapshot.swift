import Foundation

/// What Lodge keeps across launches: the workspaces in bar order, each with its tabs, selected tab, pins and
/// bookmarks; the windows and the workspace each shows; and the workspaces still being deleted.
/// Runtime state (loading, history buttons, crashes, progress, favicons, security) is not stored.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public struct Tab: Codable, Equatable, Sendable {
        public var id: TabID
        /// Nil for a blank tab.
        public var url: URL?
        public var title: String
        public var link: UUID?
    }

    /// One workspace's tabs, pins and bookmarks.
    public struct WorkspaceContent: Codable, Equatable, Sendable {
        /// In `TabList` order.
        public var tabs: [Tab]
        public var selectedTab: TabID?
        /// In shelf order.
        public var pins: [SavedLink]
        /// The root folder, with every folder's expand state.
        public var bookmarks: BookmarkFolder

        public static let empty = WorkspaceContent(tabs: TabList(), library: LinkLibrary())

        public init(tabs: TabList, library: LinkLibrary) {
            self.init(
                tabs: tabs.tabs.map { Tab(id: $0.id, url: $0.url, title: $0.title, link: $0.link) },
                selectedTab: tabs.selectedID, pins: library.links(on: .pins), bookmarks: library.bookmarks)
        }

        init(tabs: [Tab], selectedTab: TabID?, pins: [SavedLink], bookmarks: BookmarkFolder) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.pins = pins
            self.bookmarks = bookmarks
        }

        /// Tabs on `store`, isLive false, dangling link dropped, unknown selection → first tab.
        public func restored(store: StoreRef) -> (tabs: TabList, library: LinkLibrary) {
            let links = Set((pins + bookmarks.links).map(\.id))
            let restored = tabs.map {
                BrowserTab(
                    id: $0.id, store: store, url: $0.url, title: $0.title,
                    link: $0.link.flatMap { links.contains($0) ? $0 : nil }, isLive: false)
            }
            return (TabList(tabs: restored, selectedID: selectedTab), LinkLibrary(pins: pins, bookmarks: bookmarks))
        }
    }

    public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
        public var workspace: Workspace
        public var content: WorkspaceContent

        public init(workspace: Workspace, content: WorkspaceContent) {
            self.workspace = workspace
            self.content = content
        }
    }

    public struct WindowSnapshot: Codable, Equatable, Sendable {
        public var activeWorkspace: UUID

        public init(activeWorkspace: UUID) {
            self.activeWorkspace = activeWorkspace
        }
    }

    public enum DecodeError: Error, Equatable {
        /// Written by a newer Lodge.
        case unsupportedVersion(Int)
    }

    /// `currentVersion` when written.
    public var version: Int
    /// Bar order, Default first, never `.anonymous`.
    public var workspaces: [WorkspaceSnapshot]
    /// At least one; an unknown active workspace reads as Default.
    public var windows: [WindowSnapshot]
    /// Disjoint from `workspaces`.
    public var pendingDeletions: [UUID]

    /// Normalizes: Default inserted/moved first, duplicate ids and .anonymous dropped, pending ids dropped from
    /// workspaces, empty windows → [Default], unknown active → Default.
    public init(workspaces: [WorkspaceSnapshot], windows: [WindowSnapshot], pendingDeletions: [UUID]) {
        var seen: Set<UUID> = [Workspace.defaultID]
        let pending = pendingDeletions.filter { seen.insert($0).inserted }
        let kept = workspaces.filter { $0.workspace.kind != .anonymous && !pending.contains($0.workspace.id) }
        let list = WorkspaceList(workspaces: kept.map(\.workspace))
        let workspaces = list.workspaces.map { workspace in
            WorkspaceSnapshot(
                workspace: workspace, content: kept.first { $0.workspace.id == workspace.id }?.content ?? .empty)
        }
        let windows = windows.isEmpty ? [WindowSnapshot(activeWorkspace: Workspace.defaultID)] : windows
        version = Self.currentVersion
        self.workspaces = workspaces
        self.windows = windows.map { WindowSnapshot(activeWorkspace: list.resolve($0.activeWorkspace)) }
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
    /// windows = [Default]; pending = []. v1's flat bookmarks become an expanded root folder. v3: read then
    /// normalized. > 3 throws .unsupportedVersion. Always holds `currentVersion` afterwards.
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
