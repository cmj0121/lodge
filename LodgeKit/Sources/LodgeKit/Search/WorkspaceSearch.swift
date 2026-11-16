import Foundation

/// One workspace's search settings, kept in its session content and gone with it.
public struct WorkspaceSearch: Codable, Equatable, Sendable {
    /// Engines added to this workspace, in the order added. Never built-ins.
    public var engines: [SearchEngine]
    /// The chosen engine's id. nil: a custom workspace follows Default; Default and Anonymous use DuckDuckGo.
    /// Never rewritten by a fallback.
    public var choice: String?

    public static let empty = WorkspaceSearch(engines: [], choice: nil)

    public var isEmpty: Bool { engines.isEmpty && choice == nil }

    public init(engines: [SearchEngine] = [], choice: String? = nil) {
        self.engines = engines
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey {
        case engines, choice
    }

    /// A missing `engines` reads as none; `choice` is left out when nil.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engines = try container.decodeIfPresent([SearchEngine].self, forKey: .engines) ?? []
        choice = try container.decodeIfPresent(String.self, forKey: .choice)
    }
}
