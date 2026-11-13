import Testing

@testable import LodgeKit

@Suite struct ViewReleaseTests {
    @Test func stepStopsWhenShownWhateverTheTab() {
        for hasView in [false, true] {
            for isHeld in [false, true] {
                #expect(ViewRelease.step(isShown: true, hasView: hasView, isHeld: isHeld) == .stop)
            }
        }
    }

    @Test func stepSkipsHoldsOrReleasesInTheBackground() {
        #expect(ViewRelease.step(isShown: false, hasView: false, isHeld: false) == .skip)
        #expect(ViewRelease.step(isShown: false, hasView: true, isHeld: true) == .hold)
        #expect(ViewRelease.step(isShown: false, hasView: true, isHeld: false) == .release)
    }

    @Test func retryOnlyForAHeldTabStillInTheBackground() {
        #expect(ViewRelease.needsRetry(isShown: false, isAnyHeld: true))
        #expect(!ViewRelease.needsRetry(isShown: true, isAnyHeld: true))
        #expect(!ViewRelease.needsRetry(isShown: false, isAnyHeld: false))
    }

    @Test func aSecondBeginWhileRunningAsksForAnotherScan() {
        var release = ViewRelease()
        let r1 = release.begin()
        #expect(r1)
        let r2 = release.begin()
        #expect(!r2)
        let r3 = release.finishScan()
        #expect(r3)
        #expect(release.isRunning)
        let r4 = release.finishScan()
        #expect(!r4)
        #expect(!release.isRunning)
        let r5 = release.begin()
        #expect(r5)
    }

    @Test func stopDropsTheRerunAndFreesTheNextPass() {
        var release = ViewRelease()
        let r6 = release.begin()
        #expect(r6)
        let r7 = release.begin()
        #expect(!r7)
        release.stop()
        #expect(!release.isRunning)
        let r8 = release.begin()
        #expect(r8)
        let r9 = release.finishScan()
        #expect(!r9)
    }

    /// Away, back, away again while the first pass waits on a hold check: the tab rebuilt while shown is released
    /// by the first pass's rescan, not left alive in the background.
    @Test func aViewRebuiltDuringAPassIsReleasedByTheRescan() {
        var release = ViewRelease()
        var views: Set<String> = ["t0", "t1"]
        var isShown = false
        let tabs = ["t0", "t1"]

        // Pass A starts and releases t0.
        let r10 = release.begin()
        #expect(r10)
        if ViewRelease.step(isShown: isShown, hasView: views.contains("t0"), isHeld: false) == .release {
            views.remove("t0")
        }
        // A awaits t1's hold check; meanwhile the workspace is shown (t0 rebuilt) and hidden again (pass B).
        isShown = true
        views.insert("t0")
        isShown = false
        let r11 = release.begin()
        #expect(!r11)
        // A resumes with t1, then rescans because B asked.
        if ViewRelease.step(isShown: isShown, hasView: views.contains("t1"), isHeld: false) == .release {
            views.remove("t1")
        }
        var scans = 1
        while release.finishScan() {
            scans += 1
            for tab in tabs where ViewRelease.step(isShown: isShown, hasView: views.contains(tab), isHeld: false) == .release {
                views.remove(tab)
            }
        }
        #expect(scans == 2)
        #expect(views.isEmpty)
        #expect(!release.isRunning)
    }
}
