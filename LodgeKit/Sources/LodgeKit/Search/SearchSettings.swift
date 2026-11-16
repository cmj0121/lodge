import Foundation

/// What one workspace can pick and what it searches with, resolved at the moment of use.
public struct SearchCatalog: Equatable, Sendable {
    /// `SearchEngine.builtIns`, then Default's added engines, then the workspace's own (none extra for Default
    /// itself).
    public let available: [SearchEngine]
    /// The workspace's own `choice` if in `available`; else, for a custom workspace, Default's resolved engine; else
    /// `.duckDuckGo`.
    public let engine: SearchEngine
    /// A custom workspace whose `choice` is nil.
    public let followsDefault: Bool
    /// The workspace's own `choice` as stored, even if it no longer resolves.
    public let choice: String?
}

/// Every workspace's `WorkspaceSearch`; the coordinator owns one, built from and written back to session content.
/// A choice that no longer resolves is kept as stored and falls back only in `catalog(for:)`.
public struct SearchSettings: Equatable, Sendable {
    private var byWorkspace: [UUID: WorkspaceSearch]

    /// Empty entries are not kept.
    public init(_ byWorkspace: [UUID: WorkspaceSearch] = [:]) {
        self.byWorkspace = byWorkspace.filter { !$0.value.isEmpty }
    }

    /// `.empty` when absent.
    public subscript(workspace: UUID) -> WorkspaceSearch {
        byWorkspace[workspace] ?? .empty
    }

    public func catalog(for workspace: Workspace) -> SearchCatalog {
        let defaults = self[Workspace.defaultID]
        let shared = SearchEngine.builtIns + defaults.engines
        guard workspace.kind != .default else {
            return SearchCatalog(
                available: shared, engine: Self.resolve(defaults.choice, in: shared) ?? .duckDuckGo,
                followsDefault: false, choice: defaults.choice)
        }
        let own = self[workspace.id]
        let available = shared + own.engines
        let fallback = workspace.kind == .custom ? catalog(for: .default).engine : .duckDuckGo
        return SearchCatalog(
            available: available, engine: Self.resolve(own.choice, in: available) ?? fallback,
            followsDefault: workspace.kind == .custom && own.choice == nil, choice: own.choice)
    }

    /// nil = Follow Default (custom) or back to DuckDuckGo (Default/Anonymous). An id not in that workspace's
    /// `available` throws `.unknown`.
    public mutating func choose(_ engineID: String?, for workspace: Workspace) throws(SearchEngine.EditError) {
        if let engineID, !catalog(for: workspace).available.contains(where: { $0.id == engineID }) {
            throw .unknown(engineID)
        }
        var search = self[workspace.id]
        search.choice = engineID
        byWorkspace[workspace.id] = search.isEmpty ? nil : search
    }

    /// Forgets the workspace's engines and choice, as when it is deleted.
    public mutating func drop(_ workspace: UUID) {
        byWorkspace[workspace] = nil
    }

    private static func resolve(_ choice: String?, in engines: [SearchEngine]) -> SearchEngine? {
        choice.flatMap { id in engines.first { $0.id == id } }
    }
}
