import Testing

@testable import LodgeKit

@Suite struct LatestOnlyTests {
    @Test func anOlderResultArrivingAfterANewerOneIsIgnored() {
        var latest = LatestOnly()
        let older = latest.begin()
        let newer = latest.begin()
        #expect(latest.accepts(newer))
        #expect(!latest.accepts(older))
    }

    @Test func aResultArrivingAfterAClearIsIgnored() {
        var latest = LatestOnly()
        let search = latest.begin()
        let joined = latest.ticket
        latest.invalidate()
        #expect(!latest.accepts(search))
        #expect(!latest.accepts(joined))
        let next = latest.begin()
        #expect(latest.accepts(next))
    }

    @Test func joiningTheCurrentTicketDoesNotVoidIt() {
        var latest = LatestOnly()
        let load = latest.ticket
        let other = latest.ticket
        #expect(latest.accepts(load))
        #expect(latest.accepts(other))
    }
}
