import Foundation

/// What keeps each website data store alive: the tabs on it (popups and released tabs included) and its running
/// downloads. Each holder is on at most one store.
public struct StoreHolders: Equatable, Sendable {
    public enum Holder: Hashable, Sendable {
        case tab(TabID)
        case download(UUID)
    }

    private var stores: [Holder: StoreRef] = [:]
    private var holders: [StoreRef: Set<Holder>] = [:]

    public init() {}

    /// Puts `holder` on `store`, moving it off any other; returns that other store when it is left without holders.
    @discardableResult
    public mutating func attach(_ holder: Holder, to store: StoreRef) -> StoreRef? {
        let left = stores[holder] == store ? nil : detach(holder)
        stores[holder] = store
        holders[store, default: []].insert(holder)
        return left
    }

    /// Takes `holder` off its store; returns that store when `holder` was its last one, nil otherwise or when
    /// `holder` is on none.
    @discardableResult
    public mutating func detach(_ holder: Holder) -> StoreRef? {
        guard let store = stores.removeValue(forKey: holder) else { return nil }
        holders[store]?.remove(holder)
        guard holders[store]?.isEmpty ?? true else { return nil }
        holders[store] = nil
        return store
    }

    public func isHeld(_ store: StoreRef) -> Bool {
        holders[store] != nil
    }

    public func holders(of store: StoreRef) -> Set<Holder> {
        holders[store] ?? []
    }

    public func store(of holder: Holder) -> StoreRef? {
        stores[holder]
    }
}
