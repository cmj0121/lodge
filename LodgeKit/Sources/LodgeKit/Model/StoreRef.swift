import Foundation

public typealias TabID = UUID

/// The website data store a workspace's tabs use.
public enum StoreRef: Codable, Hashable, Sendable {
    /// `WKWebsiteDataStore.default()`: the Default workspace.
    case global
    /// `WKWebsiteDataStore(forIdentifier:)`: a custom workspace.
    case workspace(UUID)
    /// `WKWebsiteDataStore.nonPersistent()`, kept alive while its workspace exists: an anonymous workspace.
    case ephemeral(UUID)
}
