import Foundation
import Testing

@testable import LodgeKit

@Suite struct DownloadListTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func item(_ state: DownloadItem.State, _ name: String = "f") -> DownloadItem {
        DownloadItem(sourceURL: URL(string: "https://a.example/\(name)"), fileName: name, state: state, startedAt: now)
    }

    @Test func addPutsTheNewestFirst() {
        var list = DownloadList()
        let a = item(.running, "a"), b = item(.running, "b")
        list.add(a)
        list.add(b)
        #expect(list.items.map(\.id) == [b.id, a.id])
    }

    @Test func endedItemsBeyondTheCapAreEvictedOldestFirst() {
        var list = DownloadList()
        let ended = (0..<DownloadList.keep).map { item(.finished, "\($0)") }
        for item in ended { list.add(item) }
        let newest = item(.failed(reason: "x"), "new")
        list.add(newest)
        #expect(list.items.count == DownloadList.keep)
        #expect(list.items.first?.id == newest.id)
        #expect(list[ended[0].id] == nil)
        #expect(list[ended[1].id] != nil)
    }

    @Test func activeItemsAreNeverEvicted() {
        let active = [item(.running, "r"), item(.waitingForLocation, "w")]
        var list = DownloadList(items: active)
        for index in 0...DownloadList.keep { list.add(item(.cancelled, "\(index)")) }
        #expect(list.items.count == DownloadList.keep + 2)
        #expect(list.items.suffix(2).map(\.id) == active.map(\.id))
        #expect(list.items.filter { !$0.state.isActive }.count == DownloadList.keep)
    }

    @Test func updateChangesOneItemAndEvictsWhenItEnds() {
        var list = DownloadList()
        let running = item(.running, "r")
        list.add(running)
        for index in 0..<DownloadList.keep { list.add(item(.finished, "\(index)")) }
        #expect(list.update(running.id) { _ = $0.transition(to: .finished, at: now) })
        #expect(list[running.id] == nil)
        #expect(list.items.count == DownloadList.keep)
    }

    @Test func updateOfAnUnknownItemReturnsFalse() {
        var list = DownloadList(items: [item(.running)])
        let before = list
        #expect(!list.update(UUID()) { $0.fileName = "x" })
        #expect(list == before)
    }

    @Test func removeDropsOnlyThatItem() {
        let a = item(.finished, "a"), b = item(.running, "b")
        var list = DownloadList(items: [a, b])
        list.remove(a.id)
        #expect(list.items == [b])
    }

    @Test func clearEndedRemovesExactlyTheNonActiveItems() {
        let items = [
            item(.waitingForLocation), item(.finished), item(.running), item(.failed(reason: "x")), item(.cancelled),
            item(.interrupted),
        ]
        var list = DownloadList(items: items)
        list.clearEnded()
        #expect(list.items == [items[0], items[2]])
    }

    @Test func interruptActiveTurnsActiveItemsIntoInterruptedAndReturnsThem() {
        let later = now.addingTimeInterval(60)
        let items = [item(.running, "r"), item(.finished, "f"), item(.waitingForLocation, "w")]
        var list = DownloadList(items: items)
        let interrupted = list.interruptActive(at: later)
        #expect(interrupted.map(\.id) == [items[0].id, items[2].id])
        #expect(interrupted.allSatisfy { $0.state == .interrupted && $0.endedAt == later })
        #expect(list.items.map(\.state) == [.interrupted, .finished, .interrupted])
        #expect(list[items[1].id] == items[1])
    }
}
