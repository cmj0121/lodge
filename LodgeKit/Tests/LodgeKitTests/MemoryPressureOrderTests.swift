import Foundation
import Testing

@testable import LodgeKit

@Suite struct MemoryPressureOrderTests {
    let start = ContinuousClock.now
    let a = TabID()
    let b = TabID()
    let c = TabID()
    let d = TabID()

    /// A workspace whose tabs left the screen at the given offsets from `start`, in that order.
    func rest(_ stamps: [(TabID, Int)]) -> TabRest {
        var rest = TabRest()
        for (tab, seconds) in stamps {
            rest.update(shown: [tab], now: start + .seconds(seconds))
            rest.update(shown: [], now: start + .seconds(seconds))
        }
        return rest
    }

    @Test func workspacesMergeByLastSeenOldestFirst() {
        let first = rest([(a, 10), (b, 30)])
        let second = rest([(c, 5), (d, 20)])
        #expect(TabRest.oldestFirst([(first, [a, b]), (second, [c, d])], shown: []) == [c, a, d, b])
    }

    @Test func tabsNeverStampedComeLastInWorkspaceThenTabOrder() {
        let first = rest([(a, 10)])
        let second = rest([(c, 5)])
        #expect(TabRest.oldestFirst([(first, [b, a]), (second, [d, c])], shown: []) == [c, a, b, d])
    }

    @Test func shownTabsAreLeftOut() {
        var first = rest([(a, 10)])
        first.update(shown: [b], now: start + .seconds(20))
        let second = rest([(c, 5), (d, 30)])
        #expect(TabRest.oldestFirst([(first, [a, b]), (second, [c, d])], shown: [c]) == [a, d])
    }

    @Test func equalStampsKeepWorkspaceOrder() {
        let first = rest([(a, 10)])
        let second = rest([(c, 10)])
        #expect(TabRest.oldestFirst([(second, [c]), (first, [a])], shown: []) == [c, a])
        #expect(TabRest.oldestFirst([(first, [a]), (second, [c])], shown: []) == [a, c])
    }

    @Test func onlyLiveTabsAreOrdered() {
        let first = rest([(a, 10), (b, 20)])
        #expect(TabRest.oldestFirst([(first, [b])], shown: []) == [b])
        #expect(TabRest.oldestFirst([], shown: []).isEmpty)
    }
}
