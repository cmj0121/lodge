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
    public static let anonymousID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let anonymousName = "Anonymous"
    public static let anonymousSymbol = "theatermasks"
    public static let anonymous = Workspace(
        id: anonymousID, name: anonymousName, symbol: anonymousSymbol, kind: .anonymous)

    public let id: UUID
    /// Trimmed, non-empty and unique (case-insensitive) within a `WorkspaceList`.
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    public let kind: WorkspaceKind

    /// `.global` for Default, `.workspace(id)` for a custom one; nil for Anonymous, whose tabs each get their own.
    public var store: StoreRef? {
        switch kind {
        case .default: .global
        case .custom: .workspace(id)
        case .anonymous: nil
        }
    }

    /// Default or Anonymous: never renamed, moved or removed.
    public var isFixed: Bool { kind != .custom }

    public init(id: UUID = UUID(), name: String, symbol: String, kind: WorkspaceKind = .custom) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.kind = kind
    }
}

/// The workspaces in bar order. Default is always first and cannot be renamed, moved or removed; Anonymous is
/// always last and cannot be changed at all.
public struct WorkspaceList: Equatable, Sendable {
    public enum EditError: Error, Equatable {
        case emptyName, nameTooLong, duplicateName, emptySymbol, unknown(UUID), defaultIsFixed, anonymousIsFixed
    }

    public static let nameLimit = 40

    /// `[0]` is always Default and the last is always `Workspace.anonymous`.
    public private(set) var workspaces: [Workspace]

    public init() {
        workspaces = [.default, .anonymous]
    }

    /// Keeps one Default first (the listed one's name and symbol, else `Workspace.default`), the custom workspaces in
    /// order without duplicate ids, and exactly one `Workspace.anonymous` last; any other `.default` or `.anonymous`
    /// workspace and any custom one using a fixed id are dropped.
    public init(workspaces: [Workspace]) {
        let listed = workspaces.first { $0.id == Workspace.defaultID }
        let defaultWorkspace =
            listed.map { Workspace(id: $0.id, name: $0.name, symbol: $0.symbol, kind: .default) } ?? .default
        var seen: Set<UUID> = [Workspace.defaultID, Workspace.anonymousID]
        self.workspaces =
            [defaultWorkspace] + workspaces.filter { $0.kind == .custom && seen.insert($0.id).inserted }
            + [.anonymous]
    }

    public subscript(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    public var `default`: Workspace { workspaces[0] }

    public var anonymous: Workspace { workspaces[workspaces.count - 1] }

    /// `id` when it is listed, else Default's.
    public func resolve(_ id: UUID?) -> UUID {
        id.flatMap { self[$0]?.id } ?? Workspace.defaultID
    }

    /// The ⌘-number slots in order: 1 is Default, 2…9 the next custom workspaces; Anonymous has none.
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

    /// Adds a custom workspace at the end of the customs, just before Anonymous.
    @discardableResult
    public mutating func create(name: String, symbol: String) throws(EditError) -> Workspace {
        let name = try validate(name: name).get()
        let workspace = Workspace(name: name, symbol: try Self.validate(symbol: symbol))
        workspaces.insert(workspace, at: workspaces.count - 1)
        return workspace
    }

    /// The workspace's own current name does not count as a duplicate.
    public mutating func rename(_ id: UUID, to name: String) throws(EditError) {
        let index = try customIndex(of: id)
        workspaces[index].name = try validate(name: name, renaming: id).get()
    }

    /// Default included; Anonymous refused.
    public mutating func setSymbol(_ id: UUID, _ symbol: String) throws(EditError) {
        let index = try index(of: id)
        guard id != Workspace.anonymousID else { throw .anonymousIsFixed }
        workspaces[index].symbol = try Self.validate(symbol: symbol)
    }

    /// Moves the custom workspace at `source` to end at `destination`, clamped among the customs. False when
    /// `source` is not a custom workspace or nothing changes.
    @discardableResult
    public mutating func move(from source: Int, to destination: Int) -> Bool {
        let last = workspaces.count - 2
        guard 1 <= source, source <= last else { return false }
        let destination = min(max(destination, 1), last)
        guard destination != source else { return false }
        workspaces.insert(workspaces.remove(at: source), at: destination)
        return true
    }

    @discardableResult
    public mutating func remove(_ id: UUID) throws(EditError) -> Workspace {
        workspaces.remove(at: try customIndex(of: id))
    }

    /// The trimmed name when it is non-empty, at most `nameLimit` characters and unlike (case-insensitive)
    /// every other workspace's name, Anonymous's included; `renaming` names the workspace whose own name is ignored.
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

    private func customIndex(of id: UUID) throws(EditError) -> Int {
        let index = try index(of: id)
        switch workspaces[index].kind {
        case .default: throw .defaultIsFixed
        case .anonymous: throw .anonymousIsFixed
        case .custom: return index
        }
    }
}
