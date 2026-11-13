import Foundation
import Testing

@testable import LodgeKit

@Suite struct StoreHoldersTests {
    private let store = StoreRef.ephemeral(UUID())
    private let other = StoreRef.ephemeral(UUID())
    private let tab = StoreHolders.Holder.tab(TabID())
    private let popup = StoreHolders.Holder.tab(TabID())
    private let download = StoreHolders.Holder.download(UUID())

    @Test func startsHoldingNothing() {
        let holders = StoreHolders()
        #expect(!holders.isHeld(store))
        #expect(holders.holders(of: store).isEmpty)
        #expect(holders.store(of: tab) == nil)
    }

    @Test func attachHoldsTheStore() {
        var holders = StoreHolders()
        #expect(holders.attach(tab, to: store) == nil)
        #expect(holders.attach(popup, to: store) == nil)
        #expect(holders.isHeld(store))
        #expect(!holders.isHeld(other))
        #expect(holders.holders(of: store) == [tab, popup])
        #expect(holders.store(of: popup) == store)
    }

    @Test func detachReturnsTheStoreOnlyForItsLastHolder() {
        var holders = StoreHolders()
        holders.attach(tab, to: store)
        holders.attach(download, to: store)
        #expect(holders.detach(tab) == nil)
        #expect(holders.isHeld(store))
        #expect(holders.detach(download) == store)
        #expect(!holders.isHeld(store))
        #expect(holders.holders(of: store).isEmpty)
        #expect(holders.store(of: download) == nil)
        #expect(holders == StoreHolders())
    }

    @Test func detachingAnUnknownHolderChangesNothing() {
        var holders = StoreHolders()
        holders.attach(tab, to: store)
        let before = holders
        #expect(holders.detach(popup) == nil)
        #expect(holders == before)
    }

    @Test func attachMovesAHolderAndReportsTheStoreItLeftEmpty() {
        var holders = StoreHolders()
        holders.attach(tab, to: store)
        #expect(holders.attach(tab, to: other) == store)
        #expect(!holders.isHeld(store))
        #expect(holders.holders(of: other) == [tab])
        holders.attach(popup, to: other)
        #expect(holders.attach(popup, to: store) == nil)
        #expect(holders.holders(of: other) == [tab])
    }

    @Test func reattachingToTheSameStoreChangesNothing() {
        var holders = StoreHolders()
        holders.attach(tab, to: store)
        let before = holders
        #expect(holders.attach(tab, to: store) == nil)
        #expect(holders == before)
    }
}
