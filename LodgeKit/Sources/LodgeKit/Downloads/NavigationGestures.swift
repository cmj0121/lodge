import Foundation

/// What each recent navigation action said about itself, for the response it gets: WebKit does not link a
/// `WKNavigationResponse` to its action. Records are kept per request URL (without its fragment) and frame kind for
/// `lifetime`; a response whose URL has no record (it was redirected) takes the latest main-frame action, or for a
/// subframe the latest gestured subframe action (WebKit gives frames no public identity to key them by).
public struct NavigationGestures: Sendable {
    public struct Record: Equatable, Sendable {
        public let userInitiated: Bool
        /// The download site (`DownloadGate.site(source:target:)`).
        public let site: Origin?

        public init(userInitiated: Bool, site: Origin?) {
            self.userInitiated = userInitiated
            self.site = site
        }
    }

    static let lifetime: Duration = .seconds(30)

    private struct Key: Hashable {
        let url: String
        let isMainFrame: Bool
    }

    private var records: [Key: (record: Record, at: ContinuousClock.Instant)] = [:]
    private var latestMainFrame: (record: Record, at: ContinuousClock.Instant)?
    private var latestGesturedSubframe: (record: Record, at: ContinuousClock.Instant)?

    public init() {}

    public mutating func record(
        _ record: Record, url: URL?, isMainFrame: Bool, at now: ContinuousClock.Instant = .now
    ) {
        records = records.filter { now - $0.value.at < Self.lifetime }
        if isMainFrame {
            latestMainFrame = (record, now)
        } else if record.userInitiated {
            latestGesturedSubframe = (record, now)
        }
        guard let key = Self.key(url, isMainFrame) else { return }
        records[key] = (record, now)
    }

    /// The record for a response to `url`; nil when there is none within `lifetime`.
    public func record(for url: URL?, isMainFrame: Bool, at now: ContinuousClock.Instant = .now) -> Record? {
        if let key = Self.key(url, isMainFrame), let found = records[key], now - found.at < Self.lifetime {
            return found.record
        }
        guard let latest = isMainFrame ? latestMainFrame : latestGesturedSubframe, now - latest.at < Self.lifetime
        else { return nil }
        return latest.record
    }

    private static func key(_ url: URL?, _ isMainFrame: Bool) -> Key? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        return components.string.map { Key(url: $0, isMainFrame: isMainFrame) }
    }
}
