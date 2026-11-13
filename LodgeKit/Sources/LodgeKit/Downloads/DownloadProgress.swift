import Foundation

/// Coalesces progress ticks so the list changes at most once per `interval`. A tick inside the interval asks for
/// one flush at its end; ticks before that flush wait for it, so the latest bytes always land.
public struct DownloadProgressThrottle: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Apply the progress now.
        case emit
        /// Apply it in `after` seconds, then call `flushed(at:)`.
        case schedule(after: TimeInterval)
        /// A flush is already scheduled and will apply it.
        case wait
    }

    /// At most 10 updates per second.
    public static let interval: TimeInterval = 0.1

    private var lastEmit: TimeInterval?
    private var isScheduled = false

    public init() {}

    /// `now` is a monotonic time in seconds.
    public mutating func offer(at now: TimeInterval) -> Decision {
        guard !isScheduled else { return .wait }
        if let lastEmit, now - lastEmit < Self.interval {
            isScheduled = true
            return .schedule(after: Self.interval - (now - lastEmit))
        }
        lastEmit = now
        return .emit
    }

    /// The scheduled flush ran at `now`.
    public mutating func flushed(at now: TimeInterval) {
        isScheduled = false
        lastEmit = now
    }
}

/// What the sidebar's downloads button shows for the whole list.
public enum DownloadOverallProgress: Equatable, Sendable {
    /// Nothing is active.
    case none
    /// Σreceived / Σtotal of the running items, in 0…1.
    case determinate(Double)
    /// An item is waiting for its location, or a running one has no known total.
    case indeterminate

    public init(_ items: [DownloadItem]) {
        var received: Int64 = 0
        var total: Int64 = 0
        var isActive = false
        for item in items {
            switch item.state {
            case .waitingForLocation:
                self = .indeterminate
                return
            case .running:
                guard let itemTotal = item.totalBytes else {
                    self = .indeterminate
                    return
                }
                isActive = true
                received += min(item.receivedBytes, itemTotal)
                total += itemTotal
            case .finished, .failed, .cancelled, .interrupted:
                continue
            }
        }
        guard isActive else {
            self = .none
            return
        }
        self = total > 0 ? .determinate(Double(received) / Double(total)) : .indeterminate
    }
}

extension DownloadList {
    public var overallProgress: DownloadOverallProgress { DownloadOverallProgress(items) }
}
