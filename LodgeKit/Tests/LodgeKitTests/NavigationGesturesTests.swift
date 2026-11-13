import Foundation
import Testing

@testable import LodgeKit

@Suite struct NavigationGesturesTests {
    private let start = ContinuousClock.now
    private let url = URL(string: "https://a.example/f.zip#top")!
    private let clicked = NavigationGestures.Record(
        userInitiated: true, site: Origin(url: URL(string: "https://a.example/")!))

    @Test func aSubframeResponseFindsItsActionByURLAndFrame() {
        var gestures = NavigationGestures()
        gestures.record(clicked, url: url, isMainFrame: false, at: start)
        #expect(
            gestures.record(for: URL(string: "https://a.example/f.zip"), isMainFrame: false, at: start) == clicked)
        #expect(gestures.record(for: url, isMainFrame: true, at: start) == nil)
    }

    @Test func aRedirectedMainFrameResponseTakesTheLatestMainFrameAction() {
        var gestures = NavigationGestures()
        gestures.record(clicked, url: url, isMainFrame: true, at: start)
        #expect(
            gestures.record(for: URL(string: "https://cdn.example/f.zip"), isMainFrame: true, at: start) == clicked)
    }

    @Test func aRedirectedSubframeResponseTakesTheLatestGesturedSubframeAction() {
        var gestures = NavigationGestures()
        gestures.record(clicked, url: url, isMainFrame: false, at: start)
        let scripted = NavigationGestures.Record(userInitiated: false, site: clicked.site)
        gestures.record(scripted, url: URL(string: "https://a.example/ad"), isMainFrame: false, at: start)
        let redirected = URL(string: "https://cdn.example/f.zip")
        #expect(gestures.record(for: redirected, isMainFrame: false, at: start) == clicked)
        #expect(gestures.record(for: redirected, isMainFrame: false, at: start + NavigationGestures.lifetime) == nil)
    }

    @Test func aSubframeWithoutAGestureLeavesNoFallback() {
        var gestures = NavigationGestures()
        let scripted = NavigationGestures.Record(userInitiated: false, site: clicked.site)
        gestures.record(scripted, url: url, isMainFrame: false, at: start)
        #expect(gestures.record(for: URL(string: "https://cdn.example/f.zip"), isMainFrame: false, at: start) == nil)
    }

    @Test func recordsExpire() {
        var gestures = NavigationGestures()
        gestures.record(clicked, url: url, isMainFrame: false, at: start)
        gestures.record(clicked, url: url, isMainFrame: true, at: start)
        let later = start + NavigationGestures.lifetime
        #expect(gestures.record(for: url, isMainFrame: false, at: later) == nil)
        #expect(gestures.record(for: url, isMainFrame: true, at: later) == nil)
    }
}
