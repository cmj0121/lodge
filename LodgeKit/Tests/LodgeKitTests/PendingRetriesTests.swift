import Foundation
import Testing

@testable import LodgeKit

@Suite struct PendingRetriesTests {
    let row = UUID()
    let store = StoreRef.workspace(UUID())

    @Test func aRetryWhoseStoreStaysIsTracked() {
        var pending = PendingRetries()
        pending.begin(row, on: store)
        let tracked = pending.finish(row, storeExists: true)
        let trackedAgain = pending.finish(row, storeExists: true)
        #expect(tracked)
        #expect(!trackedAgain)
    }

    @Test func aRetryWhoseStoreWasCancelledWhileStartingIsNotTracked() {
        var pending = PendingRetries()
        pending.begin(row, on: store)
        pending.cancel(store: store)
        let tracked = pending.finish(row, storeExists: true)
        #expect(!tracked)
    }

    @Test func aRetryWhoseStoreIsGoneOnReturnIsNotTracked() {
        var pending = PendingRetries()
        pending.begin(row, on: store)
        let tracked = pending.finish(row, storeExists: false)
        #expect(!tracked)
    }

    @Test func cancellingAStoreLeavesOtherStoresRetries() {
        var pending = PendingRetries()
        let other = UUID()
        pending.begin(row, on: store)
        pending.begin(other, on: .global)
        pending.cancel(store: store)
        let tracked = pending.finish(other, storeExists: true)
        #expect(tracked)
    }
}
