import Foundation

/// Which downloads a page may start (CWE-770), kept for the run in memory only. A download is user-initiated when
/// the user clicked a link (an `<a download>` included) or submitted a form: WebKit has no public user-gesture flag,
/// so the navigation type stands in for one (a script's `a.click()` reports a link activation too, hence the burst
/// rule). Per site (the origin of the frame that started the download, `site(source:target:)`) on each store, so
/// no two workspaces or Anonymous tabs share an answer or a count:
/// - the first download without a gesture runs; each further one asks;
/// - more than `burstLimit` downloads within `burstWindow`, gestured or not, ask too;
/// - the answer holds for that site on that store until quit, or until `forget(store:)`.
/// A download without a site (an opaque frame) runs only with a gesture, so no two pages share an answer; those
/// share one burst count per store, and past it they are refused, as there is no host to name in a prompt.
public struct DownloadGate: Sendable {
    public enum Refusal: Equatable, Sendable {
        /// From a subframe without a gesture: refused silently.
        case subframe
        /// From a frame that has no site, without a gesture or past the burst limit: refused silently.
        case noSite
        /// `maxActive` downloads are running: the user is told.
        case tooMany
        /// The user answered Don't Allow for the site.
        case denied
        /// The site's prompt is open; the download does not queue another.
        case prompting
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Ask the user (`prompt(for:)`), then report the answer with `answer(_:for:)`.
        case ask
        case refuse(Refusal)
    }

    public static let maxActive = 10
    static let burstLimit = 3
    static let burstWindow: Duration = .seconds(10)

    private struct Key: Hashable, Sendable {
        let store: StoreRef
        let site: Origin
    }

    private var startedUnprompted: Set<Key> = []
    private var answers: [Key: Bool] = [:]
    private var prompting: Set<Key> = []
    private var recent: [Key: [ContinuousClock.Instant]] = [:]
    private var recentWithoutSite: [StoreRef: [ContinuousClock.Instant]] = [:]

    public init() {}

    /// The site a download counts against: the source frame's origin, else (a typed URL in a fresh tab) the target
    /// URL's; the target URL's for a load the browser started (address bar, bookmark, history); nil when neither is
    /// a scheme with a host.
    public static func site(source: Origin, target: URL?, browserInitiated: Bool = false) -> Origin? {
        if !browserInitiated, isSite(source) { return source }
        guard let target else { return nil }
        let origin = Origin(url: target)
        return isSite(origin) ? origin : nil
    }

    private static func isSite(_ origin: Origin) -> Bool { !origin.isOpaque && !origin.host.isEmpty }

    /// Decides one download of `site` on `store`, `activeCount` downloads already running, and records it when it
    /// may run or asks. `.ask` marks the site's prompt open until `answer(_:for:on:)`.
    public mutating func decide(
        store: StoreRef, site: Origin?, userInitiated: Bool, isMainFrame: Bool, activeCount: Int,
        at now: ContinuousClock.Instant = .now
    ) -> Decision {
        guard isMainFrame || userInitiated else { return .refuse(.subframe) }
        guard let site else {
            guard userInitiated else { return .refuse(.noSite) }
            guard activeCount < Self.maxActive else { return .refuse(.tooMany) }
            var starts = recentWithoutSite[store, default: []].filter { now - $0 < Self.burstWindow }
            guard starts.count < Self.burstLimit else { return .refuse(.noSite) }
            starts.append(now)
            recentWithoutSite[store] = starts
            return .allow
        }
        let key = Key(store: store, site: site)
        guard !prompting.contains(key) else { return .refuse(.prompting) }
        guard activeCount < Self.maxActive else { return .refuse(.tooMany) }
        var starts = recent[key, default: []].filter { now - $0 < Self.burstWindow }
        let isBurst = starts.count >= Self.burstLimit
        let needsAnswer = isBurst || (!userInitiated && startedUnprompted.contains(key))
        let decision: Decision
        if !needsAnswer {
            if !userInitiated { startedUnprompted.insert(key) }
            decision = .allow
        } else if let allowed = answers[key] {
            decision = allowed ? .allow : .refuse(.denied)
        } else {
            prompting.insert(key)
            decision = .ask
        }
        if decision != .refuse(.denied) { starts.append(now) }
        recent[key] = starts
        return decision
    }

    /// Closes the site's prompt on `store` and remembers the answer for the rest of the run.
    public mutating func answer(_ allowed: Bool, for site: Origin, on store: StoreRef) {
        let key = Key(store: store, site: site)
        prompting.remove(key)
        answers[key] = allowed
    }

    /// Drops everything recorded for `store`, an anonymous tab's that is gone.
    public mutating func forget(store: StoreRef) {
        startedUnprompted = startedUnprompted.filter { $0.store != store }
        answers = answers.filter { $0.key.store != store }
        prompting = prompting.filter { $0.store != store }
        recent = recent.filter { $0.key.store != store }
        recentWithoutSite[store] = nil
    }

    public static func prompt(for site: Origin) -> String {
        "Allow \(site.host) to download multiple files?"
    }
}
