import Foundation
import os

/// The file work of a download (D6): where its partial goes, moving it to the final file, and deleting partials.
/// Only `.lodgedownload` files are ever deleted.
public struct DownloadFiles: Sendable {
    /// How a finished partial takes its final name.
    public enum Placement: Equatable, Sendable {
        /// A folder Lodge picked the name in: a file that took the name meanwhile makes it pick a unique one.
        case unique
        /// The file chosen in the save panel, whose overwrite the user already approved: it is replaced.
        case exact
    }

    private static let logger = Logger(subsystem: "dev.lodge", category: "downloads")

    /// Partials that cannot sit beside their final file are kept here, named after their item.
    public let stagingFolder: URL

    public init(stagingFolder: URL) {
        self.stagingFolder = stagingFolder
    }

    public func stagedPartial(of id: UUID) -> URL {
        stagingFolder.appending(path: id.uuidString).appendingPathExtension(DownloadNaming.partialExtension)
    }

    /// The partial beside `finalURL` when it can be created there (a folder picked in the save panel grants only the
    /// chosen file), else the staged one, creating the staging folder. Leaves no file behind: WebKit needs the
    /// destination not to exist.
    public func partialURL(for finalURL: URL, id: UUID) -> URL {
        let beside = DownloadNaming.partialURL(for: finalURL)
        if FileManager.default.createFile(atPath: beside.path(percentEncoded: false), contents: nil) {
            Self.deletePartial(beside)
            return beside
        }
        try? FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        return stagedPartial(of: id)
    }

    /// Moves `partial` to `finalURL` and returns where it landed. `.unique` picks a unique name (also skipping
    /// `reserved`) when `finalURL` exists; `.exact` removes it first. Only the granted file is touched, never its
    /// folder, so this works across volumes and in a folder the sandbox grants just that file of.
    public func finish(
        _ partial: URL, to finalURL: URL, placement: Placement, reserved: Set<String> = []
    ) throws -> URL {
        let exists = FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false))
        switch placement {
        case .exact:
            if exists { try FileManager.default.removeItem(at: finalURL) }
            try FileManager.default.moveItem(at: partial, to: finalURL)
            return finalURL
        case .unique:
            var target = finalURL
            if exists {
                let folder = finalURL.deletingLastPathComponent()
                target = folder.appending(
                    path: DownloadNaming.unique(finalURL.lastPathComponent, in: folder, reserved: reserved))
            }
            try FileManager.default.moveItem(at: partial, to: target)
            return target
        }
    }

    /// After relaunch: deletes the partials of interrupted `items` beside their final names, and every partial in
    /// the staging folder, each only when it was created before `cutoff` (so a download started meanwhile keeps its
    /// own). `folder` is the custom downloads folder, when there is one: it is accessed (security-scoped) around the
    /// deletes.
    public func cleanUp(_ items: [DownloadItem], createdBefore cutoff: Date, folder: URL? = nil) {
        let accessing = folder?.startAccessingSecurityScopedResource() == true
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
        var partials = items.filter { $0.state == .interrupted }.compactMap { item in
            item.directory.map { DownloadNaming.partialURL(for: $0.appending(path: item.fileName)) }
        }
        let staged = try? FileManager.default.contentsOfDirectory(
            at: stagingFolder, includingPropertiesForKeys: [.creationDateKey])
        partials += staged ?? []
        for partial in partials {
            guard let created = try? partial.resourceValues(forKeys: [.creationDateKey]).creationDate,
                created < cutoff
            else { continue }
            Self.deletePartial(partial)
        }
    }

    /// Deletes `url` only when it is a `.lodgedownload` partial; a missing file is fine, any other failure is logged.
    @discardableResult
    public static func deletePartial(_ url: URL) -> Bool {
        guard url.pathExtension == DownloadNaming.partialExtension else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return false
        } catch {
            logger.error("Cannot delete a partial download: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
