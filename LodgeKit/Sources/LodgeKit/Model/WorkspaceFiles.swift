import Foundation

/// Where each workspace keeps its files in the app's Application Support directory: Default its history in the
/// directory itself, where it always was, its tab places in `Places/` and its link icons in `Icons/`; every other
/// workspace in `Workspaces/<uuid>/`.
public enum WorkspaceFiles {
    /// Default → `app` (keeps `history.sqlite`); custom → `app/Workspaces/<uuid>/`; anonymous → nil, it keeps none.
    public static func historyDirectory(for workspace: Workspace, in app: URL) -> URL? {
        switch workspace.kind {
        case .default: app
        case .custom: directory(for: workspace.id, in: app)
        case .anonymous: nil
        }
    }

    /// Where the workspace's resting tabs keep their place (`PlaceStore`): Default → `app/Places/`, beside its history;
    /// custom → `app/Workspaces/<uuid>/Places/`, removed with the workspace; anonymous → nil, it keeps none.
    public static func placesDirectory(for workspace: Workspace, in app: URL) -> URL? {
        switch workspace.kind {
        case .default: app.appending(path: placesName, directoryHint: .isDirectory)
        case .custom: directory(for: workspace.id, in: app).appending(path: placesName, directoryHint: .isDirectory)
        case .anonymous: nil
        }
    }

    /// Where the workspace's pins and bookmarks keep their icons (`LinkIconCache`): Default → `app/Icons/`; custom →
    /// `app/Workspaces/<uuid>/Icons/`, removed with the workspace; anonymous → nil, it keeps none on disk.
    public static func iconsDirectory(for workspace: Workspace, in app: URL) -> URL? {
        switch workspace.kind {
        case .default: app.appending(path: iconsName, directoryHint: .isDirectory)
        case .custom: directory(for: workspace.id, in: app).appending(path: iconsName, directoryHint: .isDirectory)
        case .anonymous: nil
        }
    }

    private static let placesName = "Places"
    private static let iconsName = "Icons"

    /// A workspace's own directory; never Default's, whose files sit in `app` itself.
    public static func directory(for id: UUID, in app: URL) -> URL {
        app.appending(path: "Workspaces", directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// Deletes the workspace's directory with everything in it (`-wal`, `-shm` and `.bad` included). A missing
    /// one succeeds, and so does Default, whose files are never removed.
    public static func remove(_ id: UUID, in app: URL) throws {
        guard id != Workspace.defaultID else { return }
        do {
            try FileManager.default.removeItem(at: directory(for: id, in: app))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}
