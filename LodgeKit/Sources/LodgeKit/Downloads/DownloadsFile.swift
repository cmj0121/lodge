import Foundation

/// The download list on disk: `downloads.json` in `directory`. A file that cannot be read is moved aside to
/// `downloads.json.bad` (replacing an older one) so the next launch starts with an empty list. Loaded items are
/// sanitized (`DownloadItem.sanitizedForLoad()`).
public struct DownloadsFile: Sendable {
    public static let currentVersion = 1

    public enum DecodeError: Error, Equatable {
        /// Written by a newer Lodge.
        case unsupportedVersion(Int)
    }

    public enum LoadOutcome: Sendable {
        case missing
        case loaded(DownloadList)
        /// The file could not be read or decoded, or came from a newer Lodge. `moveFailure` is set when it
        /// could not be moved aside either.
        case setAside(reason: any Error, moveFailure: (any Error)? = nil)

        public var list: DownloadList? {
            if case .loaded(let list) = self { list } else { nil }
        }
    }

    /// What `downloads.json` holds.
    struct Contents: Codable {
        var version: Int
        var items: [DownloadItem]

        init(version: Int = DownloadsFile.currentVersion, items: [DownloadItem]) {
            self.version = version
            self.items = items
        }

        private enum CodingKeys: String, CodingKey {
            case version, items
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The version is read first, so a newer file is reported as such rather than as malformed.
            version = try container.decode(Int.self, forKey: .version)
            guard version <= DownloadsFile.currentVersion else { throw DecodeError.unsupportedVersion(version) }
            items = try container.decode([DownloadItem].self, forKey: .items)
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var url: URL { directory.appending(path: "downloads.json") }

    public var badURL: URL { url.appendingPathExtension("bad") }

    public func load() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        do {
            let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
            return .loaded(DownloadList(items: contents.items.map { $0.sanitizedForLoad() }))
        } catch {
            do {
                try setAside()
                return .setAside(reason: error)
            } catch let moveFailure {
                return .setAside(reason: error, moveFailure: moveFailure)
            }
        }
    }

    private func setAside() throws {
        if FileManager.default.fileExists(atPath: badURL.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: badURL)
        }
        try FileManager.default.moveItem(at: url, to: badURL)
    }

    /// Writes `list` atomically, creating `directory` when it is missing.
    public func write(_ list: DownloadList) throws {
        try write(Contents(items: list.items))
    }

    func write(_ contents: Contents) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
