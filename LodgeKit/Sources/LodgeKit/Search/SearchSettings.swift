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

    /// Adds an engine to the workspace with a new UUID id, after Default's and its earlier ones; Default's engines
    /// are offered in every workspace, any other workspace's only in it. The name and template are trimmed; a
    /// refused one changes nothing.
    @discardableResult
    public mutating func add(name: String, template: String, to workspace: UUID) throws(SearchEngine.EditError)
        -> SearchEngine
    {
        let fields = try SearchEngine.validate(name: name, template: template).get()
        let engine = SearchEngine(id: UUID().uuidString, name: fields.name, template: fields.template)
        byWorkspace[workspace, default: .empty].engines.append(engine)
        return engine
    }

    /// Renames or readdresses one of the workspace's added engines in place, keeping its id, so every choice naming
    /// it follows. Built-ins throw `.builtInIsFixed`, an id not added to this workspace `.unknown`, a refused name or
    /// template its `validate` error; a refusal changes nothing.
    public mutating func update(_ engineID: String, name: String, template: String, in workspace: UUID)
        throws(SearchEngine.EditError)
    {
        let index = try ownIndex(of: engineID, in: workspace)
        let fields = try SearchEngine.validate(name: name, template: template).get()
        byWorkspace[workspace]?.engines[index].name = fields.name
        byWorkspace[workspace]?.engines[index].template = fields.template
    }

    /// Built-ins throw `.builtInIsFixed`, an id not added to this workspace `.unknown`. Choices naming it are left
    /// as they are; they fall back at resolution: a custom workspace to Default's engine, Default and Anonymous to
    /// DuckDuckGo.
    public mutating func remove(_ engineID: String, from workspace: UUID) throws(SearchEngine.EditError) {
        let index = try ownIndex(of: engineID, in: workspace)
        var search = self[workspace]
        search.engines.remove(at: index)
        byWorkspace[workspace] = search.isEmpty ? nil : search
    }

    /// The other workspaces (Anonymous included, Default excluded) whose `choice` is this Default engine, in id
    /// order; none for an id that is not one of Default's added engines.
    public func dependents(of engineID: String) -> [UUID] {
        guard self[Workspace.defaultID].engines.contains(where: { $0.id == engineID }) else { return [] }
        return byWorkspace.filter { $0.key != Workspace.defaultID && $0.value.choice == engineID }.keys
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Forgets the workspace's engines and choice, as when it is deleted.
    public mutating func drop(_ workspace: UUID) {
        byWorkspace[workspace] = nil
    }

    private func ownIndex(of engineID: String, in workspace: UUID) throws(SearchEngine.EditError) -> Int {
        if SearchEngine.builtIns.contains(where: { $0.id == engineID }) { throw .builtInIsFixed }
        guard let index = self[workspace].engines.firstIndex(where: { $0.id == engineID }) else {
            throw .unknown(engineID)
        }
        return index
    }

    private static func resolve(_ choice: String?, in engines: [SearchEngine]) -> SearchEngine? {
        choice.flatMap { id in engines.first { $0.id == id } }
    }
}
