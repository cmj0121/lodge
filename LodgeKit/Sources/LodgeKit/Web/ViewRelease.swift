/// Paces the release of a background workspace's web views: one pass runs at a time, a release asked for while one
/// runs makes it scan every tab again before it ends, and a pass stops as soon as the workspace is shown again.
public struct ViewRelease: Equatable, Sendable {
    /// What a pass does with one tab.
    public enum Step: Equatable, Sendable {
        /// The workspace is shown again: the pass ends, releasing nothing more.
        case stop
        /// The tab has no web view.
        case skip
        /// Playing, capturing, fullscreen or popup-paired: kept, and tried again later.
        case hold
        case release
    }

    public private(set) var isRunning = false
    private var isRerunRequested = false

    public init() {}

    /// Starts a pass, true; while one runs, asks it to scan again and returns false.
    public mutating func begin() -> Bool {
        guard !isRunning else {
            isRerunRequested = true
            return false
        }
        isRunning = true
        isRerunRequested = false
        return true
    }

    /// Ends a scan of every tab: true when a release was asked for meanwhile, so the pass scans again; false ends it.
    public mutating func finishScan() -> Bool {
        if isRerunRequested {
            isRerunRequested = false
            return true
        }
        isRunning = false
        return false
    }

    /// Ends the pass at once (the workspace is shown), dropping any rerun asked for.
    public mutating func stop() {
        isRunning = false
        isRerunRequested = false
    }

    /// The step for a tab, decided after its hold check, from the state then.
    public static func step(isShown: Bool, hasView: Bool, isHeld: Bool) -> Step {
        if isShown { return .stop }
        if !hasView { return .skip }
        return isHeld ? .hold : .release
    }

    /// After a finished pass: a held tab in a workspace still in the background is tried again later.
    public static func needsRetry(isShown: Bool, isAnyHeld: Bool) -> Bool { isAnyHeld && !isShown }
}
