import Foundation

/// One download as the Downloads list shows it and `downloads.json` stores it.
public struct DownloadItem: Identifiable, Codable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case waitingForLocation, running, finished, failed(reason: String), cancelled, interrupted

        /// Waiting for its save location or receiving bytes; every other state is ended.
        public var isActive: Bool {
            switch self {
            case .waitingForLocation, .running: true
            case .finished, .failed, .cancelled, .interrupted: false
            }
        }
    }

    public let id: UUID
    /// The original request URL.
    public var sourceURL: URL?
    /// "GET", "POST", …
    public var method: String
    /// The final (reserved) name.
    public var fileName: String
    /// The folder it is saved in, for display and as the Show in Finder fallback.
    public var directory: URL?
    /// The final file, set on finish.
    public var fileURL: URL?
    /// Security-scoped, set on finish.
    public var bookmark: Data?
    public var state: State
    public var receivedBytes: Int64
    /// `nil` while the total is unknown.
    public var totalBytes: Int64?
    public let startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID = UUID(), sourceURL: URL?, method: String = "GET", fileName: String, directory: URL? = nil,
        fileURL: URL? = nil, bookmark: Data? = nil, state: State = .waitingForLocation, receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil, startedAt: Date, endedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.method = method
        self.fileName = fileName
        self.directory = directory
        self.fileURL = fileURL
        self.bookmark = bookmark
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// The request was a GET over http(s), so it can be sent again (D8).
    public var isReplayable: Bool {
        guard method.uppercased() == "GET", let scheme = sourceURL?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Ended without a file (failed, cancelled or interrupted), and the request is replayable.
    public var canRetry: Bool {
        switch state {
        case .failed, .cancelled, .interrupted: isReplayable
        case .waitingForLocation, .running, .finished: false
        }
    }

    /// `canRetry`, or finished with its file moved or deleted (`isMissing`, D5) and the request replayable.
    public func canRetry(isMissing: Bool) -> Bool {
        canRetry || (state == .finished && isMissing && isReplayable)
    }

    /// The item as read back from downloads.json: a name that is not one safe path component is sanitized, so
    /// cleanup never builds a path out of its folder (a safe one is kept as stored, so cleanup finds the partial
    /// an older sanitizer named), and a source that is not http(s) is dropped, so it cannot be retried. A container
    /// someone else can write to is out of scope; this only keeps a stale or malformed list from doing harm.
    public func sanitizedForLoad() -> DownloadItem {
        var item = self
        if !DownloadNaming.isSafeComponent(fileName) { item.fileName = DownloadNaming.sanitize(fileName) }
        let scheme = sourceURL?.scheme?.lowercased()
        if scheme != "http" && scheme != "https" { item.sourceURL = nil }
        return item
    }

    /// Allowed: waitingForLocation → running | cancelled | failed; running → finished | failed | cancelled |
    /// interrupted; ended states are final (Retry makes a new item). Entering an ended state sets `endedAt`.
    /// Returns false and changes nothing otherwise.
    public mutating func transition(to state: State, at date: Date) -> Bool {
        let allowed =
            switch (self.state, state) {
            case (.waitingForLocation, .running), (.waitingForLocation, .cancelled), (.waitingForLocation, .failed):
                true
            case (.running, .finished), (.running, .failed), (.running, .cancelled), (.running, .interrupted):
                true
            default:
                false
            }
        guard allowed else { return false }
        self.state = state
        if !state.isActive { endedAt = date }
        return true
    }
}
