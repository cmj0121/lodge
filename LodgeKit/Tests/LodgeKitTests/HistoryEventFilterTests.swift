import Foundation
import Testing

@testable import LodgeKit

@Suite struct HistoryEventFilterTests {
    private let tab = UUID()
    private let page = URL(string: "https://a.example/")!

    @Test func aCommitIsRecorded() {
        let filter = HistoryEventFilter(tab: tab)
        #expect(
            filter.committed(page, title: "A", store: .global, isRestore: false)
                == .committed(tab: tab, url: page, title: "A"))
    }

    @Test func theRestoreCommitIsOnlySeen() {
        let filter = HistoryEventFilter(tab: tab)
        #expect(filter.committed(page, title: "A", store: .global, isRestore: true) == .seen(tab: tab, url: page))
    }

    @Test func theInitialURLIsIgnored() {
        var filter = HistoryEventFilter(tab: tab)
        #expect(filter.urlChanged(page, title: "A", store: .global, isLoading: false) == nil)
        #expect(
            filter.urlChanged(page, title: "A", store: .global, isLoading: false)
                == .urlChanged(tab: tab, url: page, title: "A"))
    }

    @Test func aURLChangeWhileLoadingIsLeftToTheCommit() {
        var filter = HistoryEventFilter(tab: tab)
        _ = filter.urlChanged(nil, title: "", store: .global, isLoading: false)
        #expect(filter.urlChanged(page, title: "", store: .global, isLoading: true) == nil)
        #expect(filter.urlChanged(nil, title: "", store: .global, isLoading: false) == nil)
    }

    @Test func titlesAreSent() {
        #expect(
            HistoryEventFilter(tab: tab).titleChanged("A", url: page, store: .global)
                == .title(tab: tab, url: page, title: "A"))
    }

    @Test func aTitleWithoutAURLIsNotSent() {
        #expect(HistoryEventFilter(tab: tab).titleChanged("A", url: nil, store: .global) == nil)
    }

    @Test func blankTitlesAreNotSent() {
        let filter = HistoryEventFilter(tab: tab)
        #expect(filter.titleChanged("", url: page, store: .global) == nil)
        #expect(filter.titleChanged(" \n\t", url: page, store: .global) == nil)
    }

    @Test func aFinishedLoadSendsItsFinalWebURL() {
        let filter = HistoryEventFilter(tab: tab)
        let routed = URL(string: "https://a.example/app/home")!
        #expect(
            filter.loadFinished(routed, title: "A", store: .global) == .urlChanged(tab: tab, url: routed, title: "A"))
        #expect(filter.loadFinished(nil, title: "", store: .global) == nil)
        #expect(filter.loadFinished(routed, title: "A", store: nil) == nil)
    }

    @Test func everyStoreIsRecorded() {
        var filter = HistoryEventFilter(tab: tab)
        _ = filter.urlChanged(page, title: "", store: .global, isLoading: false)
        for store in [StoreRef.workspace(UUID()), .ephemeral(UUID())] {
            #expect(
                filter.committed(page, title: "A", store: store, isRestore: false)
                    == .committed(tab: tab, url: page, title: "A"))
            #expect(filter.committed(page, title: "A", store: store, isRestore: true) == .seen(tab: tab, url: page))
            #expect(
                filter.urlChanged(page, title: "A", store: store, isLoading: false)
                    == .urlChanged(tab: tab, url: page, title: "A"))
            #expect(filter.titleChanged("A", url: page, store: store) == .title(tab: tab, url: page, title: "A"))
            #expect(
                filter.loadFinished(page, title: "A", store: store) == .urlChanged(tab: tab, url: page, title: "A"))
        }
    }

    @Test func closedTabsSendNothing() {
        var filter = HistoryEventFilter(tab: tab)
        _ = filter.urlChanged(page, title: "", store: .global, isLoading: false)
        #expect(filter.committed(page, title: "A", store: nil, isRestore: false) == nil)
        #expect(filter.urlChanged(page, title: "A", store: nil, isLoading: false) == nil)
        #expect(filter.titleChanged("A", url: page, store: nil) == nil)
    }
}
