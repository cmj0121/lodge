import Foundation

public enum WorkspaceKind: String, Codable, Sendable {
    case `default`, custom, anonymous
}

/// A set of tabs, pins and bookmarks on its own website data store.
public struct Workspace: Identifiable, Codable, Hashable, Sendable {
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static let defaultName = "Default"
    public static let defaultSymbol = "square.stack.3d.up"
    public static let `default` = Workspace(id: defaultID, name: defaultName, symbol: defaultSymbol, kind: .default)

    public let id: UUID
    /// Trimmed, non-empty and unique (case-insensitive) within a `WorkspaceList`.
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    public let kind: WorkspaceKind

    /// Derived from `kind` and `id`; tabs never store their own.
    public var store: StoreRef {
        switch kind {
        case .default: .global
        case .custom: .workspace(id)
        case .anonymous: .ephemeral(id)
        }
    }

    public init(id: UUID = UUID(), name: String, symbol: String, kind: WorkspaceKind = .custom) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.kind = kind
    }
}

/// The workspaces in bar order. Default is always first and cannot be renamed, moved or removed.
public struct WorkspaceList: Equatable, Sendable {
    public enum EditError: Error, Equatable {
        case emptyName, nameTooLong, duplicateName, emptySymbol, unknown(UUID), defaultIsFixed
    }

    public static let nameLimit = 40

    /// `[0]` is always Default.
    public private(set) var workspaces: [Workspace]

    public init() {
        workspaces = [.default]
    }

    /// Keeps one Default first (the listed one, else `Workspace.default`) and drops duplicate ids and any other
    /// `.default` workspace.
    public init(workspaces: [Workspace]) {
        let listed = workspaces.first { $0.id == Workspace.defaultID }
        let defaultWorkspace =
            listed.map { Workspace(id: $0.id, name: $0.name, symbol: $0.symbol, kind: .default) } ?? .default
        var seen: Set<UUID> = [Workspace.defaultID]
        self.workspaces =
            [defaultWorkspace] + workspaces.filter { $0.kind != .default && seen.insert($0.id).inserted }
    }

    public subscript(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public var `default`: Workspace { workspaces[0] }

    /// `id` when it is listed, else Default's.
    public func resolve(_ id: UUID?) -> UUID {
        id.flatMap { self[$0]?.id } ?? Workspace.defaultID
    }

    /// The ⌘-number slots in order: 1 is Default, 2…9 the next non-anonymous workspaces.
    private var slotted: [Workspace] {
        Array(workspaces.filter { $0.kind != .anonymous }.prefix(9))
    }

    public func workspace(forSlot slot: Int) -> Workspace? {
        let slotted = slotted
        return slotted.indices.contains(slot - 1) ? slotted[slot - 1] : nil
    }

    public func slot(of id: UUID) -> Int? {
        slotted.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// Appends a custom workspace.
    @discardableResult
    public mutating func create(name: String, symbol: String) throws(EditError) -> Workspace {
        let name = try validate(name: name).get()
        let workspace = Workspace(name: name, symbol: try Self.validate(symbol: symbol))
        workspaces.append(workspace)
        return workspace
    }

    /// The workspace's own current name does not count as a duplicate.
    public mutating func rename(_ id: UUID, to name: String) throws(EditError) {
        let index = try index(of: id)
        guard index != 0 else { throw .defaultIsFixed }
        workspaces[index].name = try validate(name: name, renaming: id).get()
    }

    /// Default included.
    public mutating func setSymbol(_ id: UUID, _ symbol: String) throws(EditError) {
        let index = try index(of: id)
        workspaces[index].symbol = try Self.validate(symbol: symbol)
    }

    /// Moves the workspace at `source` to end at `destination`, clamped to `1...`. False when `source` is
    /// Default or out of range, or nothing changes.
    @discardableResult
    public mutating func move(from source: Int, to destination: Int) -> Bool {
        guard source != 0, workspaces.indices.contains(source) else { return false }
        let destination = min(max(destination, 1), workspaces.count - 1)
        guard destination != source else { return false }
        workspaces.insert(workspaces.remove(at: source), at: destination)
        return true
    }

    @discardableResult
    public mutating func remove(_ id: UUID) throws(EditError) -> Workspace {
        let index = try index(of: id)
        guard index != 0 else { throw .defaultIsFixed }
        return workspaces.remove(at: index)
    }

    /// The trimmed name when it is non-empty, at most `nameLimit` characters and unlike (case-insensitive)
    /// every other workspace's name; `renaming` names the workspace whose own name is ignored.
    public func validate(name: String, renaming id: UUID? = nil) -> Result<String, EditError> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard name.count <= Self.nameLimit else { return .failure(.nameTooLong) }
        let taken = workspaces.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return taken ? .failure(.duplicateName) : .success(name)
    }

    private static func validate(symbol: String) throws(EditError) -> String {
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !symbol.isEmpty else { throw .emptySymbol }
        return symbol
    }

    private func index(of id: UUID) throws(EditError) -> Int {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { throw .unknown(id) }
        return index
    }
}
