import Foundation
import os

/// The file work of a download (D6): where its partial goes, moving it to the final file, and deleting partials.
/// Only `.lodgedownload` files (regular files or symlinks, never folders) are ever deleted.
public struct DownloadFiles: Sendable {
    public enum FinishError: LocalizedError, Equatable {
        /// The partial was swapped for a link, folder or other non-file while it downloaded.
        case notARegularFile

        public var errorDescription: String? {
            switch self {
            case .notARegularFile: "The downloaded file was replaced before it could be saved."
            }
        }
    }

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

    /// The partial beside `finalURL` when it can be created there as a new file (a folder picked in the save panel
    /// grants only the chosen file; an existing `.lodgedownload` or link there is never replaced), else the staged
    /// one, creating the staging folder. Leaves no file behind: WebKit needs the destination not to exist.
    public func partialURL(for finalURL: URL, id: UUID) -> URL {
        let beside = DownloadNaming.partialURL(for: finalURL)
        let descriptor = open(beside.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        if descriptor >= 0 {
            close(descriptor)
            Self.deletePartial(beside)
            return beside
        }
        try? FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        return stagedPartial(of: id)
    }

    /// Moves `partial` to `finalURL` and returns where it landed. `.unique` picks a unique name (also skipping
    /// `reserved`) when `finalURL` exists, a dangling link included; `.exact` removes it first. Only the granted file
    /// is touched, never its folder, so this works across volumes and in a folder the sandbox grants just that file
    /// of. Throws `FinishError.notARegularFile` when `partial` is not a regular file (a link put in its place).
    public func finish(
        _ partial: URL, to finalURL: URL, placement: Placement, reserved: Set<String> = []
    ) throws -> URL {
        guard Self.fileType(of: partial) == S_IFREG else { throw FinishError.notARegularFile }
        let exists = Self.fileType(of: finalURL) != nil
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
    /// own). An item's partial is only deleted when its folder is `downloadsFolder`, the custom `folder` or the
    /// staging folder, so a tampered list cannot point the deletes elsewhere. `folder` is the custom downloads
    /// folder, when there is one: it is accessed (security-scoped) around the deletes.
    public func cleanUp(
        _ items: [DownloadItem], createdBefore cutoff: Date, downloadsFolder: URL, folder: URL? = nil
    ) {
        let accessing = folder?.startAccessingSecurityScopedResource() == true
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
        let allowed = Set([downloadsFolder, stagingFolder, folder].compactMap { $0.map(Self.folderPath) })
        var partials = items.filter { $0.state == .interrupted }.compactMap { item -> URL? in
            guard let directory = item.directory, allowed.contains(Self.folderPath(directory)) else {
                return nil
            }
            return DownloadNaming.partialURL(for: directory.appending(path: item.fileName))
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

    /// Deletes `url` only when it is a `.lodgedownload` partial that is a regular file or a link (the link itself,
    /// never what it points to; never a folder); a missing file is fine, any other failure is logged.
    @discardableResult
    public static func deletePartial(_ url: URL) -> Bool {
        guard url.pathExtension == DownloadNaming.partialExtension,
            let type = fileType(of: url), type == S_IFREG || type == S_IFLNK
        else { return false }
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

    /// The standardized path, without a trailing "/", so a folder compares equal however its URL was made.
    private static func folderPath(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The `S_IFMT` bits of `url` itself (links are not followed); nil when nothing is there.
    public static func fileType(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}
