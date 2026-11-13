import Foundation

/// Where downloads are saved, as the user chose in Settings. The app persists it in UserDefaults.
public struct DownloadSettings: Equatable, Sendable {
    /// `nil` saves to ~/Downloads.
    public var folderBookmark: Data?
    public var askEachTime: Bool

    public static let folderKey = "downloads.folderBookmark", askKey = "downloads.askEachTime"

    public init(folderBookmark: Data? = nil, askEachTime: Bool = false) {
        self.folderBookmark = folderBookmark
        self.askEachTime = askEachTime
    }
}

/// Where the next download goes.
public enum DownloadDestination: Equatable, Sendable {
    /// `scoped` = needs start/stopAccessingSecurityScopedResource.
    case folder(URL, scoped: Bool)
    /// Ask with a save panel.
    case ask
    /// The custom folder's bookmark could not be resolved, so ~/Downloads is used.
    case fallback(URL)

    /// Asking wins over any folder; a custom folder is used when `resolve` turns its bookmark into a URL.
    public static func resolve(
        _ settings: DownloadSettings, downloadsFolder: URL, resolve: (Data) -> URL?
    ) -> DownloadDestination {
        if settings.askEachTime { return .ask }
        guard let bookmark = settings.folderBookmark else { return .folder(downloadsFolder, scoped: false) }
        guard let folder = resolve(bookmark) else { return .fallback(downloadsFolder) }
        return .folder(folder, scoped: true)
    }
}
