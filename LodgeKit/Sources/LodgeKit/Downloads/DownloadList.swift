import Foundation

/// Every download Lodge remembers, newest first. At most `keep` ended items are kept; active ones always are.
public struct DownloadList: Codable, Equatable, Sendable {
    public static let keep = 200

    public private(set) var items: [DownloadItem]

    public init(items: [DownloadItem] = []) {
        self.items = items
        evict()
    }

    public subscript(id: UUID) -> DownloadItem? { items.first { $0.id == id } }

    /// Inserts `item` at the top, then evicts.
    public mutating func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        evict()
    }

    /// Applies `change` to the item with `id`, then evicts; false when there is no such item.
    @discardableResult public mutating func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        change(&items[index])
        evict()
        return true
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Removes every item that is not active.
    public mutating func clearEnded() {
        items.removeAll { !$0.state.isActive }
    }

    /// After relaunch: every active item becomes interrupted; returns them (for partial-file cleanup).
    public mutating func interruptActive(at date: Date) -> [DownloadItem] {
        var interrupted: [DownloadItem] = []
        for index in items.indices where items[index].state.isActive {
            // Set directly: waitingForLocation → interrupted is not a live transition, only a relaunch one.
            items[index].state = .interrupted
            items[index].endedAt = date
            interrupted.append(items[index])
        }
        evict()
        return interrupted
    }

    /// Drops ended items beyond `keep`, oldest first.
    private mutating func evict() {
        var ended = 0
        items.removeAll { item in
            guard !item.state.isActive else { return false }
            ended += 1
            return ended > Self.keep
        }
    }
}
