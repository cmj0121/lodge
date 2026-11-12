import Foundation

/// Rate limit for one tab's JavaScript dialogs: once 3 dialogs arrive within 10 seconds, or the
/// user asks to block them, the tab gets no more dialogs until it commits a page of another origin,
/// so reloading or navigating within the same site keeps the count and the block.
public struct DialogGate: Sendable {
    private static let limit = 3
    private static let window: Duration = .seconds(10)
    public private(set) var isBlocked = false
    private var recent: [ContinuousClock.Instant] = []
    private var origin: Origin?

    public init() {}

    /// Whether a dialog requested at `now` may be shown; records it when it may.
    public mutating func admit(at now: ContinuousClock.Instant = .now) -> Bool {
        guard !isBlocked else { return false }
        recent.removeAll { now - $0 >= Self.window }
        guard recent.count < Self.limit else {
            isBlocked = true
            return false
        }
        recent.append(now)
        return true
    }

    public mutating func block() { isBlocked = true }

    /// Records a committed page; the limit starts over only when its origin differs from the last one.
    public mutating func commit(origin newOrigin: Origin) {
        guard newOrigin != origin else { return }
        origin = newOrigin
        isBlocked = false
        recent = []
    }

    /// Dialog title naming the frame's origin; an opaque one is named as an embedded page.
    public static func title(for origin: Origin) -> String {
        origin.isOpaque ? "An embedded page says" : "\(origin) says"
    }
}
