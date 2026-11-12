import Foundation

public typealias TabID = UUID

/// The website data store a tab uses; `workspace` carries the workspace's store identifier.
public enum StoreRef: Codable, Hashable, Sendable {
    case global
    case workspace(UUID)
}
