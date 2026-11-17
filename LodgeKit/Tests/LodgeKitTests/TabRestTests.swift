import Foundation
import Testing

@testable import LodgeKit

@Suite struct TabRestTests {
    let start = ContinuousClock.now
    let a = TabID()
    let b = TabID()
    let c = TabID()

    @Test func aTabIsDueOnlyOnceTheIntervalHasPassed() {
        var rest = TabRest()
        rest.update(shown: [a], now: start)
        rest.update(shown: [b], now: start)
        #expect(rest.due([a, b], after: .seconds(60), now: start + .seconds(59)).isEmpty)
        #expect(rest.due([a, b], after: .seconds(60), now: start + .seconds(60)) == [a])
    }

    @Test func aShownTabIsNeverDue() {
        var rest = TabRest()
        rest.update(shown: [a], now: start)
        #expect(rest.due([a], after: .seconds(1), now: start + .seconds(3600)).isEmpty)
        #expect(rest.nextDue([a], after: .seconds(1)) == nil)
    }

    @Test func aTabThatLeftTheScreenIsStampedThen() {
        var rest = TabRest()
        rest.update(shown: [a], now: start)
        rest.update(shown: [a], now: start + .seconds(10))
        rest.update(shown: [b], now: start + .seconds(30))
        #expect(rest.lastSeen(a) == start + .seconds(30))
        #expect(rest.due([a], after: .seconds(60), now: start + .seconds(89)).isEmpty)
        #expect(rest.due([a], after: .seconds(60), now: start + .seconds(90)) == [a])
    }

    @Test func aTabNeverStampedIsNeverDueAtOnce() {
        var rest = TabRest()
        rest.update(shown: [b], now: start)
        #expect(rest.lastSeen(a) == nil)
        #expect(rest.due([a], after: .zero, now: start).isEmpty)
        #expect(rest.nextDue([a], after: .seconds(60)) == nil)
        rest.update(shown: [a], now: start + .seconds(5))
        rest.update(shown: [], now: start + .seconds(5))
        #expect(rest.due([a], after: .seconds(60), now: start + .seconds(6)).isEmpty)
    }

    @Test func aLiveTabNeverShownIsStampedWhenFirstSeenLiveAndRestsLater() {
        var rest = TabRest()
        rest.update(shown: [b], live: [a, b], now: start)
        #expect(rest.lastSeen(a) == start)
        #expect(rest.due([a], after: .seconds(60), now: start).isEmpty)
        rest.update(shown: [b], live: [a, b], now: start + .seconds(30))
        #expect(rest.lastSeen(a) == start)
        #expect(rest.nextDue([a, b], after: .seconds(60)) == start + .seconds(60))
        #expect(rest.due([a, b], after: .seconds(60), now: start + .seconds(60)) == [a])
    }

    @Test func nextDueIsTheEarliestUnshownLiveTabPlusTheInterval() {
        var rest = TabRest()
        rest.update(shown: [a], now: start)
        rest.update(shown: [b], now: start + .seconds(10))
        rest.update(shown: [c], now: start + .seconds(20))
        #expect(rest.nextDue([a, b, c], after: .seconds(60)) == start + .seconds(70))
        #expect(rest.nextDue([b, c], after: .seconds(60)) == start + .seconds(80))
        #expect(rest.nextDue([c], after: .seconds(60)) == nil)
        #expect(rest.nextDue([], after: .seconds(60)) == nil)
    }

    @Test func dueAndOldestFirstPutTheLeastRecentlySeenFirst() {
        var rest = TabRest()
        rest.update(shown: [b], now: start)
        rest.update(shown: [a], now: start + .seconds(10))
        rest.update(shown: [c], now: start + .seconds(20))
        let never = TabID()
        #expect(rest.oldestFirst([a, b, c, never]) == [never, b, a])
        #expect(rest.due([a, b, c, never], after: .seconds(5), now: start + .seconds(100)) == [b, a])
    }

    @Test func oldestFirstKeepsTheGivenOrderForEqualStamps() {
        var rest = TabRest()
        rest.update(shown: [a, b], now: start)
        rest.update(shown: [], now: start)
        #expect(rest.oldestFirst([b, a]) == [b, a])
        #expect(rest.oldestFirst([a, b]) == [a, b])
    }

    @Test func forgetDropsTheTab() {
        var rest = TabRest()
        rest.update(shown: [a], now: start)
        rest.update(shown: [], now: start)
        rest.forget(a)
        #expect(rest.lastSeen(a) == nil)
        #expect(rest.due([a], after: .zero, now: start + .seconds(100)).isEmpty)
        #expect(rest.nextDue([a], after: .seconds(1)) == nil)
        rest.update(shown: [a], now: start)
        rest.forget(a)
        #expect(rest == TabRest())
    }

    @Test func restAfterLoadsTheStoredChoice() throws {
        let suite = "TabRestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RestAfter.load(from: defaults) == .five)
        defaults.set(37, forKey: RestAfter.defaultsKey)
        #expect(RestAfter.load(from: defaults) == .five)
        defaults.set("soon", forKey: RestAfter.defaultsKey)
        #expect(RestAfter.load(from: defaults) == .five)
        for choice in RestAfter.allCases {
            defaults.set(choice.rawValue, forKey: RestAfter.defaultsKey)
            #expect(RestAfter.load(from: defaults) == choice)
        }
    }

    @Test func aTabWithAPageAndNoViewIsResting() throws {
        let page = try #require(URL(string: "https://example.com/"))
        #expect(BrowserTab(url: page, isLive: false).isResting)
        #expect(!BrowserTab(url: page, isLive: true).isResting)
        #expect(!BrowserTab(isLive: false).isResting)
        #expect(!BrowserTab(url: LodgePage.settings.url, isLive: false).isResting)
    }

    @Test func restAfterIntervalIsInMinutesAndNeverHasNone() {
        #expect(RestAfter.standard == .five)
        #expect(RestAfter.five.interval == .seconds(300))
        #expect(RestAfter.sixty.interval == .seconds(3600))
        #expect(RestAfter.never.interval == nil)
    }
}
