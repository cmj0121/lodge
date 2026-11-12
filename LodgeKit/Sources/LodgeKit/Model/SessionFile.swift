import Foundation

/// The saved session on disk: `session.json` in `directory`. A file that cannot be read is moved aside to
/// `session.json.bad` (replacing an older one) so the next launch starts fresh.
public struct SessionFile: Sendable {
    public enum LoadOutcome: Sendable {
        case missing
        case loaded(SessionSnapshot)
        /// The file could not be read or decoded, or came from a newer Lodge. `moveFailure` is set when it
        /// could not be moved aside either.
        case setAside(reason: any Error, moveFailure: (any Error)? = nil)

        public var snapshot: SessionSnapshot? {
            if case .loaded(let snapshot) = self { snapshot } else { nil }
        }
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var url: URL { directory.appending(path: "session.json") }

    public var badURL: URL { url.appendingPathExtension("bad") }

    public func load() -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return .missing }
        do {
            return .loaded(try SessionSnapshot.decode(Data(contentsOf: url)))
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

    /// Writes `snapshot` atomically, creating `directory` when it is missing.
    public func write(_ snapshot: SessionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: url, options: .atomic)
    }
}
