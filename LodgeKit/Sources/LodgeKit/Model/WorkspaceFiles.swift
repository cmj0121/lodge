import Foundation

/// Where each workspace keeps its files in the app's Application Support directory: Default its history in the
/// directory itself, where it always was; every other workspace in `Workspaces/<uuid>/`.
public enum WorkspaceFiles {
    /// Default → `app` (keeps `history.sqlite`); custom → `app/Workspaces/<uuid>/`; anonymous → nil, it keeps none.
    public static func historyDirectory(for workspace: Workspace, in app: URL) -> URL? {
        switch workspace.kind {
        case .default: app
        case .custom: directory(for: workspace.id, in: app)
        case .anonymous: nil
        }
    }

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
