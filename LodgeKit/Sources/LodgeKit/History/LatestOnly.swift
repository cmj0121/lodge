/// Tickets for async loads whose results may land out of order: a result is used only while its ticket is current.
/// `begin()` starts a load that replaces every earlier one; `ticket` joins the current generation without voiding
/// it; `invalidate()` voids every ticket handed out so far, as a clear or a new query does.
public struct LatestOnly: Equatable, Sendable {
    public private(set) var ticket: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        ticket &+= 1
        return ticket
    }

    public mutating func invalidate() {
        ticket &+= 1
    }

    public func accepts(_ ticket: UInt64) -> Bool { ticket == self.ticket }
}
