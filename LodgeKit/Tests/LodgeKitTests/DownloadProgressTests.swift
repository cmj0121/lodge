import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadProgressThrottleTests {
    @Test func theFirstTickEmits() {
        var throttle = DownloadProgressThrottle()
        #expect(throttle.offer(at: 5) == .emit)
    }

    @Test func aTickInsideTheIntervalSchedulesOneFlushAtItsEnd() throws {
        var throttle = DownloadProgressThrottle()
        _ = throttle.offer(at: 5)
        guard case .schedule(let after) = throttle.offer(at: 5.03) else {
            Issue.record("expected a schedule")
            return
        }
        #expect(abs(after - 0.07) < 1e-9)
        #expect(throttle.offer(at: 5.05) == .wait)
        #expect(throttle.offer(at: 5.09) == .wait)
    }

    @Test func afterTheFlushTheNextTickWaitsAWholeInterval() {
        var throttle = DownloadProgressThrottle()
        _ = throttle.offer(at: 5)
        _ = throttle.offer(at: 5.03)
        throttle.flushed(at: 5.1)
        #expect(throttle.offer(at: 5.15) == .schedule(after: DownloadProgressThrottle.interval - (5.15 - 5.1)))
    }

    @Test func aTickAfterTheIntervalEmits() {
        var throttle = DownloadProgressThrottle()
        _ = throttle.offer(at: 5)
        #expect(throttle.offer(at: 5.125) == .emit)
        #expect(throttle.offer(at: 5.25) == .emit)
    }

    @Test func aBurstEmitsAtMostTenTimesASecond() {
        var throttle = DownloadProgressThrottle()
        var emitted = 0
        var flushAt: TimeInterval?
        for tick in 0..<1000 {
            let now = Double(tick) / 1000
            if let due = flushAt, now >= due {
                throttle.flushed(at: now)
                emitted += 1
                flushAt = nil
            }
            switch throttle.offer(at: now) {
            case .emit: emitted += 1
            case .schedule(let after): flushAt = now + after
            case .wait: break
            }
        }
        #expect(emitted <= 10)
        #expect(emitted >= 9)
    }
}

@Suite struct DownloadOverallProgressTests {
    private func item(_ state: DownloadItem.State, received: Int64 = 0, total: Int64? = nil) -> DownloadItem {
        DownloadItem(
            sourceURL: nil, fileName: "a", state: state, receivedBytes: received, totalBytes: total,
            startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func nothingActiveIsNone() {
        #expect(DownloadOverallProgress([]) == .none)
        #expect(
            DownloadOverallProgress([
                item(.finished, received: 5, total: 5), item(.failed(reason: "x")), item(.cancelled),
                item(.interrupted),
            ]) == .none)
    }

    @Test func runningItemsWithKnownTotalsSumTheirBytes() {
        let items = [
            item(.running, received: 10, total: 40), item(.running, received: 30, total: 60),
            item(.finished, received: 100, total: 100),
        ]
        #expect(DownloadOverallProgress(items) == .determinate(0.4))
        #expect(DownloadList(items: items).overallProgress == .determinate(0.4))
    }

    @Test func anUnknownTotalIsIndeterminate() {
        #expect(
            DownloadOverallProgress([item(.running, received: 10, total: 40), item(.running, received: 3)])
                == .indeterminate)
    }

    @Test func aWaitingItemIsIndeterminate() {
        #expect(
            DownloadOverallProgress([item(.running, received: 10, total: 40), item(.waitingForLocation)])
                == .indeterminate)
    }

    @Test func zeroTotalsAreIndeterminate() {
        #expect(DownloadOverallProgress([item(.running, total: 0)]) == .indeterminate)
    }

    @Test func receivedBeyondTheTotalCountsAsTheTotal() {
        #expect(DownloadOverallProgress([item(.running, received: 50, total: 40)]) == .determinate(1))
    }
}
