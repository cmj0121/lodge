import CryptoKit
import Foundation

/// A workspace's fingerprint key and the sites it is turned off for (D3, D7). The key never leaves the session file
/// (Anonymous: memory); a page sees only the seed derived from it for its main-frame site (D1).
public struct FingerprintSettings: Codable, Hashable, Sendable {
    public static let keyLength = 32

    /// `keyLength` random bytes.
    public var key: Data
    /// Registrable domains whose pages see the real fingerprint.
    public var offSites: Set<String>

    public init(key: Data, offSites: Set<String> = []) {
        self.key = key
        self.offSites = offSites
    }

    /// A new random key, off for no site.
    public static func fresh() -> Self {
        FingerprintSettings(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// Hex of HMAC-SHA256(key, `site` UTF-8) (D1): stable per key and site, unrelated across either.
    public func seed(for site: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(site.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    public func isOff(_ site: String) -> Bool {
        offSites.contains(site)
    }

    public mutating func setOff(_ off: Bool, _ site: String) {
        if off { offSites.insert(site) } else { offSites.remove(site) }
    }

    public enum DecodeError: Error, Equatable {
        /// The stored key is not `keyLength` bytes.
        case badKeyLength(Int)
    }

    private enum CodingKeys: String, CodingKey {
        case key, offSites
    }

    /// Throws `DecodeError.badKeyLength` for a key not `keyLength` bytes; missing or malformed `offSites` reads as
    /// none, so the key survives it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(Data.self, forKey: .key)
        guard key.count == Self.keyLength else { throw DecodeError.badKeyLength(key.count) }
        offSites = (try? container.decodeIfPresent(Set<String>.self, forKey: .offSites)) ?? []
    }
}

/// Every non-Anonymous workspace's `FingerprintSettings`; the coordinator owns one, built from and written back to
/// session content. A workspace keeps the same settings from the moment it is known until it is dropped, so every
/// save writes the same key (D3). Anonymous has none here: its settings live with its store, in memory.
public struct FingerprintKeys: Equatable, Sendable {
    private var byWorkspace: [UUID: FingerprintSettings] = [:]

    /// Each of `workspaces` but Anonymous takes its `restored` settings, or `.fresh()` without any.
    public init(_ workspaces: [Workspace], restored: [UUID: FingerprintSettings] = [:]) {
        for workspace in workspaces { add(workspace, restored[workspace.id]) }
    }

    /// Nil for Anonymous and for a workspace not added.
    public subscript(workspace: UUID) -> FingerprintSettings? {
        byWorkspace[workspace]
    }

    /// Gives a new workspace `settings`, else `.fresh()`; one already known keeps its own, and Anonymous gets none.
    public mutating func add(_ workspace: Workspace, _ settings: FingerprintSettings? = nil) {
        guard workspace.kind != .anonymous, byWorkspace[workspace.id] == nil else { return }
        byWorkspace[workspace.id] = settings ?? .fresh()
    }

    /// Forgets the workspace's key and exceptions, as when it is deleted.
    public mutating func drop(_ workspace: UUID) {
        byWorkspace[workspace] = nil
    }
}
