import Foundation

/// Makes, resolves and refreshes the custom downloads folder's security-scoped bookmark.
public struct FolderBookmarks: Sendable {
    public enum Resolution: Equatable, Sendable {
        /// `refreshed` is a new bookmark when the given one was stale.
        case folder(URL, refreshed: Data?)
        /// `name` is the folder's last known name, when the bookmark still records it.
        case unavailable(name: String?)
    }

    public var make: @Sendable (URL) throws -> Data
    public var resolve: @Sendable (Data) -> Resolution
    /// The folder's name as the bookmark recorded it, without resolving it.
    public var name: @Sendable (Data) -> String?

    public init(
        make: @escaping @Sendable (URL) throws -> Data, resolve: @escaping @Sendable (Data) -> Resolution,
        name: @escaping @Sendable (Data) -> String?
    ) {
        self.make = make
        self.resolve = resolve
        self.name = name
    }

    private static func recordedName(_ bookmark: Data) -> String? {
        URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: bookmark)?.name
    }

    public static let live = FolderBookmarks(
        make: { folder in
            try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { bookmark in
            var isStale = false
            guard
                let folder = try? URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &isStale)
            else { return .unavailable(name: recordedName(bookmark)) }
            guard isStale else { return .folder(folder, refreshed: nil) }
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let refreshed = try? folder.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            return .folder(folder, refreshed: refreshed)
        },
        name: recordedName)
}

/// What Settings shows for "Save downloads to:", from the settings and what resolving the folder bookmark found.
public struct DownloadFolderChoice: Equatable, Sendable {
    public enum Selection: Hashable, Sendable {
        case downloads
        case custom(name: String)
        /// Shown as "<name> (unavailable)"; downloads go to ~/Downloads meanwhile.
        case unavailable(name: String?)

        public var title: String {
            switch self {
            case .downloads: "Downloads"
            case .custom(let name): name
            case .unavailable(let name): "\(name ?? "Chosen folder") (unavailable)"
            }
        }
    }

    public var selection: Selection
    /// "The chosen folder is unavailable; downloads go to Downloads." Hidden while asking for each file, as the
    /// folder is then not used.
    public var showsUnavailableNote: Bool

    public init(selection: Selection, showsUnavailableNote: Bool) {
        self.selection = selection
        self.showsUnavailableNote = showsUnavailableNote
    }

    /// `resolution` is what resolving `settings.folderBookmark` found; it is ignored when there is no bookmark.
    public init(_ settings: DownloadSettings, resolution: FolderBookmarks.Resolution?) {
        guard settings.folderBookmark != nil, let resolution else {
            self.init(selection: .downloads, showsUnavailableNote: false)
            return
        }
        switch resolution {
        case .folder(let folder, _):
            self.init(selection: .custom(name: folder.lastPathComponent), showsUnavailableNote: false)
        case .unavailable(let name):
            self.init(selection: .unavailable(name: name), showsUnavailableNote: !settings.askEachTime)
        }
    }
}
