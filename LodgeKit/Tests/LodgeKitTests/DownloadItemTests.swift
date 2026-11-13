import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadItemTests {
    private typealias State = DownloadItem.State

    private static let all: [State] = [
        .waitingForLocation, .running, .finished, .failed(reason: "x"), .cancelled, .interrupted,
    ]
    private static let allowed: [(State, State)] = [
        (.waitingForLocation, .running), (.waitingForLocation, .cancelled), (.waitingForLocation, .failed(reason: "x")),
        (.running, .finished), (.running, .failed(reason: "x")), (.running, .cancelled), (.running, .interrupted),
    ]

    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 2_000)

    private func item(_ state: State, url: String? = "https://a.example/f.zip", method: String = "GET")
        -> DownloadItem
    {
        DownloadItem(sourceURL: url.flatMap(URL.init(string:)), method: method, fileName: "f.zip", state: state,
                     startedAt: start)
    }

    @Test func onlyWaitingAndRunningAreActive() {
        #expect(Self.all.filter(\.isActive) == [.waitingForLocation, .running])
    }

    @Test(arguments: all) func transitionsAreAllowedExactlyPerTheTable(from: DownloadItem.State) {
        for to in Self.all {
            let original = item(from)
            var moved = original
            let isAllowed = Self.allowed.contains { $0 == (from, to) }
            #expect(moved.transition(to: to, at: end) == isAllowed, "\(from) → \(to)")
            if isAllowed {
                #expect(moved.state == to)
                #expect(moved.endedAt == (to.isActive ? nil : end))
            } else {
                #expect(moved == original, "\(from) → \(to) changed the item")
            }
        }
    }

    @Test func isReplayableOnlyForGetOverHTTP() {
        #expect(item(.finished).isReplayable)
        #expect(item(.running, url: "http://a.example/f", method: "get").isReplayable)
        #expect(!item(.finished, method: "POST").isReplayable)
        #expect(!item(.finished, url: "blob:https://a.example/1").isReplayable)
        #expect(!item(.finished, url: nil).isReplayable)
    }

    @Test func aMissingFinishedFileCanRetryWhenReplayable() {
        #expect(item(.finished).canRetry(isMissing: true))
        #expect(!item(.finished).canRetry(isMissing: false))
        #expect(!item(.finished, method: "POST").canRetry(isMissing: true))
        #expect(!item(.running).canRetry(isMissing: true))
        #expect(item(.cancelled).canRetry(isMissing: false))
    }

    @Test func canRetryOnlyEndedGetOverHTTP() {
        #expect(item(.failed(reason: "x")).canRetry)
        #expect(item(.cancelled).canRetry)
        #expect(item(.interrupted, url: "http://a.example/f").canRetry)
        #expect(item(.cancelled, method: "get").canRetry)
        #expect(!item(.finished).canRetry)
        #expect(!item(.running).canRetry)
        #expect(!item(.waitingForLocation).canRetry)
        #expect(!item(.failed(reason: "x"), method: "POST").canRetry)
        #expect(!item(.failed(reason: "x"), url: "blob:https://a.example/1").canRetry)
        #expect(!item(.failed(reason: "x"), url: "data:text/plain,hi").canRetry)
        #expect(!item(.failed(reason: "x"), url: nil).canRetry)
    }

    @Test func keepsItsStoreThroughJSON() throws {
        var saved = item(.finished)
        let id = UUID()
        saved.store = .workspace(id)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(saved))
        #expect(decoded.store == .workspace(id))
        #expect(decoded.retryStore == .workspace(id))
    }

    @Test func aRowSavedBeforeWorkspacesRetriesOnDefault() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item(.interrupted))) as! [String: Any]
        json["store"] = nil
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.store == nil)
        #expect(decoded.retryStore == .global)
    }

    @Test func aPrivateStoreRowRetriesOnItsOwnStore() {
        var private_ = item(.failed(reason: "x"))
        let store = StoreRef.ephemeral(UUID())
        private_.store = store
        #expect(private_.isPrivate)
        #expect(private_.retryStore == store)
    }

    @Test func onlyAnEphemeralStoreRowIsPrivate() {
        var row = item(.finished)
        for store in [nil, StoreRef.global, .workspace(UUID())] {
            row.store = store
            #expect(!row.isPrivate)
        }
    }
}
