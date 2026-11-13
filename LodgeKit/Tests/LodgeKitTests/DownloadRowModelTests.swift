import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadRowModelTests {
    private typealias Row = DownloadRowModel

    private let now = Date(timeIntervalSince1970: 1_000)

    private func item(
        _ state: DownloadItem.State, received: Int64 = 0, total: Int64? = nil, url: String = "https://a.example/f.zip",
        method: String = "GET"
    ) -> DownloadItem {
        DownloadItem(
            sourceURL: URL(string: url), method: method, fileName: "f.zip", state: state, receivedBytes: received,
            totalBytes: total, startedAt: now)
    }

    private func row(_ item: DownloadItem, missing: Bool = false) -> Row { Row(item, isMissing: missing) }

    @Test func waitingForLocationOnlyCancels() {
        let row = row(item(.waitingForLocation))
        #expect(row.status == "Waiting for location…")
        #expect(row.progress == .none)
        #expect(row.actions == [.cancel])
    }

    @Test func runningWithATotalShowsBothSizesAndABar() {
        let row = row(item(.running, received: 12_300_000, total: 40_000_000))
        #expect(row.status == "\(Row.size(12_300_000)) of \(Row.size(40_000_000))")
        #expect(row.progress == .determinate(12_300_000.0 / 40_000_000.0))
        #expect(row.actions == [.cancel])
    }

    @Test func runningWithoutATotalShowsTheBytesAndAnIndeterminateBar() {
        let row = row(item(.running, received: 12_300_000))
        #expect(row.status == Row.size(12_300_000))
        #expect(row.progress == .indeterminate)
        #expect(row.actions == [.cancel])
    }

    @Test func runningProgressStaysWithinTheTotal() {
        #expect(row(item(.running, received: 50, total: 40)).progress == .determinate(1))
        #expect(row(item(.running, received: 0, total: 0)).progress == .indeterminate)
    }

    @Test func finishedShowsItsSizeAndOpens() {
        let row = row(item(.finished, received: 40_000_000, total: 40_000_000))
        #expect(row.status == Row.size(40_000_000))
        #expect(row.progress == .none)
        #expect(row.actions == [.open, .showInFinder, .remove])
        #expect(row.opensOnDoubleClick)
    }

    @Test func aMissingFileCannotBeOpenedOrShownButRetries() {
        let row = row(item(.finished, received: 40_000_000), missing: true)
        #expect(row.status == "File moved or deleted")
        #expect(row.progress == .none)
        #expect(row.actions == [.retry, .remove])
        #expect(!row.opensOnDoubleClick)
    }

    @Test func aMissingFileRetriesOnlyWhenReplayable() {
        #expect(row(item(.finished, method: "POST"), missing: true).actions == [.remove])
    }

    @Test func failedShowsItsReasonAndRetries() {
        let row = row(item(.failed(reason: "Network lost")))
        #expect(row.status == "Failed — Network lost")
        #expect(row.progress == .none)
        #expect(row.actions == [.retry, .remove])
    }

    @Test func cancelledAndInterruptedRetry() {
        #expect(row(item(.cancelled)).status == "Cancelled")
        #expect(row(item(.cancelled)).actions == [.retry, .remove])
        #expect(row(item(.interrupted)).status == "Interrupted")
        #expect(row(item(.interrupted)).actions == [.retry, .remove])
    }

    @Test func retryShowsOnlyWhenTheItemCanRetry() {
        let unretriable = [item(.failed(reason: "x"), method: "POST"), item(.cancelled, url: "blob:https://a.example/1")]
        for item in unretriable {
            #expect(!item.canRetry)
            #expect(row(item).actions == [.remove])
        }
    }

    @Test func missingIsIgnoredOutsideFinished() {
        #expect(row(item(.cancelled), missing: true).status == "Cancelled")
        #expect(row(item(.waitingForLocation), missing: true).actions == [.cancel])
    }

    @Test func onlyAFinishedReachableRowOpensOnDoubleClick() {
        let states: [DownloadItem.State] = [
            .waitingForLocation, .running, .failed(reason: "x"), .cancelled, .interrupted,
        ]
        for state in states { #expect(!row(item(state)).opensOnDoubleClick) }
    }

    @Test func hasEndedNeedsAnEndedItem() {
        #expect(!DownloadList().hasEnded)
        #expect(!DownloadList(items: [item(.running), item(.waitingForLocation)]).hasEnded)
        #expect(DownloadList(items: [item(.running), item(.interrupted)]).hasEnded)
    }
}
