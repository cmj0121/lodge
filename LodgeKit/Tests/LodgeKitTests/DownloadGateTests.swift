import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadGateTests {
    private let site = Origin(url: URL(string: "https://a.example/page")!)
    private let other = Origin(url: URL(string: "https://b.example/")!)
    private let start = ContinuousClock.now

    private func decide(
        _ gate: inout DownloadGate, _ origin: Origin?? = .none, on store: StoreRef = .global, gesture: Bool = false,
        mainFrame: Bool = true, active: Int = 0, after seconds: Double = 0
    ) -> DownloadGate.Decision {
        gate.decide(
            store: store, site: origin ?? site, userInitiated: gesture, isMainFrame: mainFrame, activeCount: active,
            at: start + .seconds(seconds))
    }

    @Test func theFirstDownloadWithoutAGestureRunsAndTheNextAsks() {
        var gate = DownloadGate()
        #expect(decide(&gate) == .allow)
        #expect(decide(&gate) == .ask)
    }

    @Test func eachOriginGetsItsOwnFreeDownload() {
        var gate = DownloadGate()
        #expect(decide(&gate) == .allow)
        #expect(decide(&gate, other) == .allow)
    }

    @Test func spacedOutUserInitiatedDownloadsNeverAskNorUseTheFreeOne() {
        var gate = DownloadGate()
        for second in 0..<6 { #expect(decide(&gate, gesture: true, after: Double(second) * 5) == .allow) }
        #expect(decide(&gate, after: 40) == .allow)
    }

    @Test func moreThanThreeWithinTenSecondsAskEvenWithAGesture() {
        var gate = DownloadGate()
        for second in 0..<3 { #expect(decide(&gate, gesture: true, after: Double(second)) == .allow) }
        #expect(decide(&gate, gesture: true, after: 9.9) == .ask)
        gate.answer(false, for: site, on: .global)
        #expect(decide(&gate, gesture: true, after: 9.95) == .refuse(.denied))
        // Once the window has passed, a gestured download runs again.
        #expect(decide(&gate, gesture: true, after: 15) == .allow)
    }

    @Test func anAllowedBurstIsRemembered() {
        var gate = DownloadGate()
        for second in 0..<3 { _ = decide(&gate, gesture: true, after: Double(second)) }
        #expect(decide(&gate, gesture: true, after: 3) == .ask)
        gate.answer(true, for: site, on: .global)
        for second in 4..<10 { #expect(decide(&gate, gesture: true, after: Double(second)) == .allow) }
    }

    @Test func whileTheOriginsPromptIsOpenItsDownloadsAreRefused() {
        var gate = DownloadGate()
        _ = decide(&gate)
        #expect(decide(&gate) == .ask)
        #expect(decide(&gate) == .refuse(.prompting))
        #expect(decide(&gate, gesture: true) == .refuse(.prompting))
        #expect(decide(&gate, other) == .allow)
    }

    @Test func theAnswerIsRememberedPerOrigin() {
        var gate = DownloadGate()
        _ = decide(&gate)
        _ = decide(&gate)
        gate.answer(true, for: site, on: .global)
        #expect(decide(&gate, after: 20) == .allow)
        #expect(decide(&gate, after: 40) == .allow)

        _ = decide(&gate, other)
        #expect(decide(&gate, other) == .ask)
        gate.answer(false, for: other, on: .global)
        #expect(decide(&gate, other, after: 20) == .refuse(.denied))
        #expect(decide(&gate, other, gesture: true, after: 40) == .allow)
    }

    @Test func twoOriginsNeverShareAnAnswer() {
        var gate = DownloadGate()
        let sameHostOtherScheme = Origin(url: URL(string: "http://a.example/")!)
        let sameHostOtherPort = Origin(url: URL(string: "https://a.example:8443/")!)
        _ = decide(&gate)
        #expect(decide(&gate) == .ask)
        gate.answer(false, for: site, on: .global)
        for origin in [other, sameHostOtherScheme, sameHostOtherPort] {
            #expect(decide(&gate, origin) == .allow)
            #expect(decide(&gate, origin) == .ask)
            gate.answer(true, for: origin, on: .global)
        }
        #expect(decide(&gate, after: 20) == .refuse(.denied))
    }

    @Test func withoutASiteOnlyAGestureRuns() {
        var gate = DownloadGate()
        #expect(decide(&gate, .some(nil)) == .refuse(.noSite))
        #expect(decide(&gate, .some(nil), gesture: true) == .allow)
        #expect(decide(&gate, .some(nil), gesture: true, active: DownloadGate.maxActive) == .refuse(.tooMany))
    }

    @Test func withoutASiteMoreThanThreeWithinTenSecondsAreRefused() {
        var gate = DownloadGate()
        for second in 0..<3 {
            #expect(decide(&gate, .some(nil), gesture: true, after: Double(second)) == .allow)
        }
        #expect(decide(&gate, .some(nil), gesture: true, after: 9.9) == .refuse(.noSite))
        #expect(decide(&gate, .some(nil), gesture: true, after: 10.5) == .allow)
        // Pages with a site keep their own counts.
        #expect(decide(&gate, gesture: true, after: 10.5) == .allow)
    }

    @Test func subframesNeedAGesture() {
        var gate = DownloadGate()
        #expect(decide(&gate, mainFrame: false) == .refuse(.subframe))
        #expect(decide(&gate, gesture: true, mainFrame: false) == .allow)
        // The refused one did not use the origin's free download.
        #expect(decide(&gate) == .allow)
    }

    @Test func atMostTenRunAtOnce() {
        var gate = DownloadGate()
        #expect(decide(&gate, gesture: true, active: DownloadGate.maxActive - 1) == .allow)
        #expect(decide(&gate, gesture: true, active: DownloadGate.maxActive) == .refuse(.tooMany))
        // A refused one does not use the free download either.
        #expect(decide(&gate, active: DownloadGate.maxActive) == .refuse(.tooMany))
        #expect(decide(&gate) == .allow)
    }

    @Test func theSiteIsTheSourceFrameElseTheTarget() {
        let target = URL(string: "https://c.example/f.zip")
        #expect(DownloadGate.site(source: site, target: target) == site)
        let none = Origin(scheme: "", host: "", port: 0)
        #expect(DownloadGate.site(source: none, target: target) == Origin(url: target!))
        #expect(DownloadGate.site(source: none, target: URL(string: "data:text/plain,x")) == nil)
        #expect(DownloadGate.site(source: none, target: nil) == nil)
    }

    @Test func aLoadTheBrowserStartedCountsAgainstItsTarget() {
        let target = URL(string: "https://c.example/f.zip")
        #expect(DownloadGate.site(source: site, target: target, browserInitiated: true) == Origin(url: target!))
        #expect(DownloadGate.site(source: site, target: URL(string: "about:blank"), browserInitiated: true) == nil)
    }

    @Test func eachStoreHasItsOwnAnswersAndCounts() {
        var gate = DownloadGate()
        let anonymous = StoreRef.ephemeral(UUID())
        _ = decide(&gate)
        #expect(decide(&gate) == .ask)
        gate.answer(false, for: site, on: .global)
        #expect(decide(&gate, after: 20) == .refuse(.denied))
        #expect(decide(&gate, on: anonymous, after: 20) == .allow)
        #expect(decide(&gate, on: anonymous, after: 20) == .ask)
        gate.answer(true, for: site, on: anonymous)
        #expect(decide(&gate, on: anonymous, after: 30) == .allow)
        #expect(decide(&gate, on: .workspace(UUID()), after: 30) == .allow)
        #expect(decide(&gate, after: 40) == .refuse(.denied))
    }

    @Test func aPromptOnOneStoreDoesNotBlockAnother() {
        var gate = DownloadGate()
        _ = decide(&gate)
        #expect(decide(&gate) == .ask)
        #expect(decide(&gate) == .refuse(.prompting))
        #expect(decide(&gate, on: .ephemeral(UUID())) == .allow)
    }

    @Test func downloadsWithoutASiteCountPerStore() {
        var gate = DownloadGate()
        for second in 0..<3 { _ = decide(&gate, .some(nil), gesture: true, after: Double(second)) }
        #expect(decide(&gate, .some(nil), gesture: true, after: 4) == .refuse(.noSite))
        #expect(decide(&gate, .some(nil), on: .ephemeral(UUID()), gesture: true, after: 4) == .allow)
    }

    @Test func forgettingAStoreClearsOnlyThatStore() {
        var gate = DownloadGate()
        let anonymous = StoreRef.ephemeral(UUID())
        for store in [StoreRef.global, anonymous] {
            _ = decide(&gate, on: store)
            #expect(decide(&gate, on: store) == .ask)
            gate.answer(false, for: site, on: store)
        }
        for second in 0..<3 { _ = decide(&gate, .some(nil), on: anonymous, gesture: true, after: Double(second)) }
        gate.forget(store: anonymous)
        #expect(decide(&gate, on: anonymous, after: 20) == .allow)
        #expect(decide(&gate, .some(nil), on: anonymous, gesture: true, after: 4) == .allow)
        #expect(decide(&gate, after: 20) == .refuse(.denied))
    }

    @Test func thePromptNamesTheHost() {
        #expect(DownloadGate.prompt(for: site) == "Allow a.example to download multiple files?")
    }
}
