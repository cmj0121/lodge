/// When each tab's page is asked (again) whether it would ask before it is left. The probe runs the page's handlers,
/// so a page that does not ask is not asked again for that document; one that asks is asked again only once `every`
/// has passed, since editors drop their handler after saving without a new document. Instants are passed in, so tests
/// need no clock.
public struct BeforeUnloadSchedule: Equatable, Sendable {
    private enum Answer: Equatable, Sendable {
        case notAsking
        case asking(since: ContinuousClock.Instant)
    }

    private var answers: [TabID: Answer] = [:]

    public init() {}

    /// The answer still standing for the tab at `now`; nil when the page should be asked.
    public func known(_ tab: TabID, now: ContinuousClock.Instant, every: Duration) -> Bool? {
        switch answers[tab] {
        case nil: nil
        case .notAsking: false
        case .asking(let since): now - since < every ? true : nil
        }
    }

    /// The page answered at `now`.
    public mutating func record(_ tab: TabID, asks: Bool, at now: ContinuousClock.Instant) {
        answers[tab] = asks ? .asking(since: now) : .notAsking
    }

    /// The tab's document, view or tab went: its next document is asked afresh.
    public mutating func forget(_ tab: TabID) {
        answers[tab] = nil
    }
}
