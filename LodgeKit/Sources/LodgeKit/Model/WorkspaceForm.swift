import Foundation

/// What the workspace sheet decides without drawing anything: the name field's message and how the arrow keys walk
/// the symbol grid.
public enum WorkspaceForm {
    /// The line under the name field for a name `WorkspaceList.validate` refused.
    public static func message(for error: WorkspaceList.EditError, name: String) -> String {
        switch error {
        case .emptyName: String(localized: "Enter a name.", bundle: .module)
        case .nameTooLong: String(localized: "Use \(WorkspaceList.nameLimit) characters or fewer.", bundle: .module)
        case .duplicateName:
            String(
                localized: "A workspace named “\(name.trimmingCharacters(in: .whitespacesAndNewlines))” already exists.",
                bundle: .module)
        case .emptySymbol: String(localized: "Choose an icon.", bundle: .module)
        case .unknown: String(localized: "This workspace no longer exists.", bundle: .module)
        case .defaultIsFixed: String(localized: "The Default workspace can’t be renamed.", bundle: .module)
        case .anonymousIsFixed: String(localized: "The Anonymous workspace can’t be changed.", bundle: .module)
        }
    }

    public enum Move: Sendable { case left, right, up, down }

    /// The grid cell an arrow key lands on from `index`, in a grid of `count` cells `columns` wide; it stops at
    /// the edges instead of wrapping.
    public static func symbolIndex(from index: Int, moving move: Move, columns: Int, count: Int) -> Int {
        let target =
            switch move {
            case .left: index % columns == 0 ? index : index - 1
            case .right: index % columns == columns - 1 ? index : index + 1
            case .up: index - columns
            case .down: index + columns
            }
        return (0..<count).contains(target) ? target : index
    }
}

extension WorkspaceSymbols {
    /// The spoken name of a grid symbol or of Anonymous's fixed symbol; the symbol's own name for any other.
    public static func label(for symbol: String) -> String {
        labels[symbol] ?? symbol
    }

    private static let labels: [String: String] = [
        "square.stack.3d.up": String(localized: "Stack", bundle: .module),
        "briefcase": String(localized: "Briefcase", bundle: .module),
        "house": String(localized: "House", bundle: .module),
        "graduationcap": String(localized: "Graduation cap", bundle: .module),
        "book": String(localized: "Book", bundle: .module),
        "airplane": String(localized: "Airplane", bundle: .module),
        "car": String(localized: "Car", bundle: .module),
        "cart": String(localized: "Shopping cart", bundle: .module),
        "bag": String(localized: "Bag", bundle: .module),
        "creditcard": String(localized: "Credit card", bundle: .module),
        "banknote": String(localized: "Banknote", bundle: .module),
        "chart.line.uptrend.xyaxis": String(localized: "Chart", bundle: .module),
        "chevron.left.forwardslash.chevron.right": String(localized: "Code", bundle: .module),
        "terminal": String(localized: "Terminal", bundle: .module),
        "hammer": String(localized: "Hammer", bundle: .module),
        "wrench.and.screwdriver": String(localized: "Tools", bundle: .module),
        "paintbrush": String(localized: "Paintbrush", bundle: .module),
        "camera": String(localized: "Camera", bundle: .module),
        "music.note": String(localized: "Music", bundle: .module),
        "film": String(localized: "Film", bundle: .module),
        "gamecontroller": String(localized: "Game controller", bundle: .module),
        "sportscourt": String(localized: "Sports court", bundle: .module),
        "figure.run": String(localized: "Runner", bundle: .module),
        "heart": String(localized: "Heart", bundle: .module),
        "cross.case": String(localized: "First aid", bundle: .module),
        "leaf": String(localized: "Leaf", bundle: .module),
        "pawprint": String(localized: "Paw print", bundle: .module),
        "fork.knife": String(localized: "Fork and knife", bundle: .module),
        "cup.and.saucer": String(localized: "Cup", bundle: .module),
        "gift": String(localized: "Gift", bundle: .module),
        "person.2": String(localized: "People", bundle: .module),
        "envelope": String(localized: "Envelope", bundle: .module),
        "bubble.left.and.bubble.right": String(localized: "Chat", bundle: .module),
        "newspaper": String(localized: "Newspaper", bundle: .module),
        "globe": String(localized: "Globe", bundle: .module),
        "star": String(localized: "Star", bundle: .module),
        "flag": String(localized: "Flag", bundle: .module),
        "lightbulb": String(localized: "Light bulb", bundle: .module),
        "lock": String(localized: "Lock", bundle: .module),
        "moon": String(localized: "Moon", bundle: .module),
        "person.fill.questionmark": String(localized: "Unknown person", bundle: .module),
    ]
}

extension WorkspaceList {
    /// The `move(from:to:)` arguments for dropping workspace `dragged` onto workspace `target`: it takes the
    /// target's place, a drop onto Default lands just after it and one onto Anonymous just before it. Nil when
    /// `dragged` is Default or Anonymous, either is not listed, or nothing would move.
    public func reorder(dragging dragged: UUID, onto target: UUID) -> (from: Int, to: Int)? {
        guard let from = workspaces.firstIndex(where: { $0.id == dragged }), workspaces[from].kind == .custom,
            let index = workspaces.firstIndex(where: { $0.id == target })
        else { return nil }
        let to = Swift.min(Swift.max(index, 1), workspaces.count - 2)
        return to == from ? nil : (from, to)
    }
}
