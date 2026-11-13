import Foundation

/// Retries waiting for WebKit to hand back their download, by row, with the store each runs on. Cancelling a store
/// voids its retries, so one that returns after its workspace is deleted is cancelled, not run on the old store (D9).
public struct PendingRetries: Equatable, Sendable {
    private var stores: [UUID: StoreRef] = [:]

    public init() {}

    public mutating func begin(_ row: UUID, on store: StoreRef) {
        stores[row] = store
    }

    public mutating func cancel(store: StoreRef) {
        stores = stores.filter { $0.value != store }
    }

    /// Ends the row's wait; true when its download may be tracked, false when it must be cancelled.
    public mutating func finish(_ row: UUID, storeExists: Bool) -> Bool {
        stores.removeValue(forKey: row) != nil && storeExists
    }
}
