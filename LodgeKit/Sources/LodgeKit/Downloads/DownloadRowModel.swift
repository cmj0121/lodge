import Foundation

/// What a row of the Downloads popover shows for an item, per the D5 table: its status line, its progress view and
/// its actions.
public struct DownloadRowModel: Equatable, Sendable {
    public enum Progress: Equatable, Sendable {
        case none
        /// Received / total, in 0…1.
        case determinate(Double)
        case indeterminate
    }

    /// In the order the row shows them.
    public enum Action: Equatable, Sendable {
        case cancel, retry, open, showInFinder, remove
    }

    public let status: String
    public let progress: Progress
    public let actions: [Action]

    /// `isMissing`: a finished item's file cannot be reached; ignored in every other state.
    public init(_ item: DownloadItem, isMissing: Bool) {
        let retry: [Action] = item.canRetry(isMissing: isMissing) ? [.retry] : []
        switch item.state {
        case .waitingForLocation:
            status = "Waiting for location…"
            progress = .none
            actions = [.cancel]
        case .running:
            let received = Self.size(item.receivedBytes)
            if let total = item.totalBytes {
                status = "\(received) of \(Self.size(total))"
                progress =
                    total > 0 ? .determinate(Double(min(item.receivedBytes, total)) / Double(total)) : .indeterminate
            } else {
                status = received
                progress = .indeterminate
            }
            actions = [.cancel]
        case .finished where isMissing:
            status = "File moved or deleted"
            progress = .none
            actions = retry + [.remove]
        case .finished:
            status = Self.size(item.receivedBytes)
            progress = .none
            actions = [.open, .showInFinder, .remove]
        case .failed(let reason):
            status = "Failed — \(reason)"
            progress = .none
            actions = retry + [.remove]
        case .cancelled:
            status = "Cancelled"
            progress = .none
            actions = retry + [.remove]
        case .interrupted:
            status = "Interrupted"
            progress = .none
            actions = retry + [.remove]
        }
    }

    /// A double click opens the file: a finished one that can be reached.
    public var opensOnDoubleClick: Bool { actions.contains(.open) }

    /// A byte count as Finder writes file sizes.
    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension DownloadList {
    /// Any item has ended, so "Clear" has something to remove.
    public var hasEnded: Bool { items.contains { !$0.state.isActive } }
}
