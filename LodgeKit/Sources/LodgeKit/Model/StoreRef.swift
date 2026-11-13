import Foundation

public typealias TabID = UUID

/// The website data store a tab uses.
public enum StoreRef: Codable, Hashable, Sendable {
    /// `WKWebsiteDataStore.default()`: the Default workspace.
    case global
    /// `WKWebsiteDataStore(forIdentifier:)`: a custom workspace.
    case workspace(UUID)
    /// `WKWebsiteDataStore.nonPersistent()`: one anonymous tab's browser, shared with its popups; dropped when its
    /// last holder goes.
    case ephemeral(UUID)
}
