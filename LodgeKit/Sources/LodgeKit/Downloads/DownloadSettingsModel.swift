import Foundation
import Observation
import os

/// The Settings Downloads pane's state. Every change is written to `defaults` at once, and the app's download
/// manager reads them at each download, so they apply to the next one.
@MainActor @Observable public final class DownloadSettingsModel {
    /// What `defaults` holds. Before the first `refresh` ends, a stored folder shows by its recorded name.
    public private(set) var selection: DownloadFolderChoice.Selection
    /// False until the first `refresh` ends, so a folder is not chosen over a selection still being resolved.
    public private(set) var isResolved = false
    public private(set) var showsUnavailableNote = false
    /// The custom folder, for the panel's start and the menu's help.
    public private(set) var folder: URL?
    public var askEachTime: Bool {
        didSet {
            defaults.set(askEachTime, forKey: DownloadSettings.askKey)
            update(resolution)
        }
    }

    private static let logger = Logger(subsystem: "dev.lodge", category: "downloads")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bookmarks: FolderBookmarks
    @ObservationIgnored private var resolution: FolderBookmarks.Resolution?
    /// Drops a resolve that a later one overtook.
    @ObservationIgnored private var generation = 0

    public init(defaults: UserDefaults = .standard, bookmarks: FolderBookmarks = .live) {
        self.defaults = defaults
        self.bookmarks = bookmarks
        askEachTime = defaults.bool(forKey: DownloadSettings.askKey)
        if let bookmark = defaults.data(forKey: DownloadSettings.folderKey) {
            selection = .custom(name: bookmarks.name(bookmark) ?? "Chosen folder")
        } else {
            selection = .downloads
        }
    }

    private var settings: DownloadSettings {
        DownloadSettings(folderBookmark: defaults.data(forKey: DownloadSettings.folderKey), askEachTime: askEachTime)
    }

    /// Resolves the stored bookmark off the main actor, and stores a refreshed one once when it was stale.
    public func refresh() async {
        generation += 1
        let current = generation
        guard let bookmark = settings.folderBookmark else {
            update(nil)
            return
        }
        let bookmarks = bookmarks
        let resolved = await Task.detached { bookmarks.resolve(bookmark) }.value
        guard current == generation, defaults.data(forKey: DownloadSettings.folderKey) == bookmark else { return }
        if case .folder(_, let refreshed?) = resolved, refreshed != bookmark {
            defaults.set(refreshed, forKey: DownloadSettings.folderKey)
        }
        update(resolved)
    }

    /// Saves to ~/Downloads from now on.
    public func useDownloads() {
        defaults.removeObject(forKey: DownloadSettings.folderKey)
        generation += 1
        update(nil)
    }

    /// What the folder panel returned: `nil` when it was cancelled. Bookmarks the folder while the panel's grant is
    /// still held, then shows what `defaults` now holds.
    public func useFolder(_ chosen: URL?) async {
        if let chosen {
            do {
                let bookmark = try bookmarks.make(chosen)
                if bookmark != defaults.data(forKey: DownloadSettings.folderKey) {
                    defaults.set(bookmark, forKey: DownloadSettings.folderKey)
                }
            } catch {
                Self.logger.error(
                    "Cannot bookmark the downloads folder: \(error.localizedDescription, privacy: .public)")
            }
        }
        await refresh()
    }

    private func update(_ resolution: FolderBookmarks.Resolution?) {
        self.resolution = resolution
        isResolved = true
        let choice = DownloadFolderChoice(settings, resolution: resolution)
        selection = choice.selection
        showsUnavailableNote = choice.showsUnavailableNote
        if case .folder(let url, _) = resolution { folder = url } else { folder = nil }
    }
}
