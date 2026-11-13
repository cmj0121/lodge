import Foundation

/// What the workspace sheet decides without drawing anything: the name field's message and how the arrow keys walk
/// the symbol grid.
public enum WorkspaceForm {
    /// The line under the name field for a name `WorkspaceList.validate` refused.
    public static func message(for error: WorkspaceList.EditError, name: String) -> String {
        switch error {
        case .emptyName: "Enter a name."
        case .nameTooLong: "Use \(WorkspaceList.nameLimit) characters or fewer."
        case .duplicateName:
            "A workspace named “\(name.trimmingCharacters(in: .whitespacesAndNewlines))” already exists."
        case .emptySymbol: "Choose an icon."
        case .unknown: "This workspace no longer exists."
        case .defaultIsFixed: "The Default workspace can’t be renamed."
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
    /// The spoken name of a grid symbol; the symbol's own name for one not in the grid.
    public static func label(for symbol: String) -> String {
        labels[symbol] ?? symbol
    }

    private static let labels: [String: String] = [
        "square.stack.3d.up": "Stack",
        "briefcase": "Briefcase",
        "house": "House",
        "graduationcap": "Graduation cap",
        "book": "Book",
        "airplane": "Airplane",
        "car": "Car",
        "cart": "Shopping cart",
        "bag": "Bag",
        "creditcard": "Credit card",
        "banknote": "Banknote",
        "chart.line.uptrend.xyaxis": "Chart",
        "chevron.left.forwardslash.chevron.right": "Code",
        "terminal": "Terminal",
        "hammer": "Hammer",
        "wrench.and.screwdriver": "Tools",
        "paintbrush": "Paintbrush",
        "camera": "Camera",
        "music.note": "Music",
        "film": "Film",
        "gamecontroller": "Game controller",
        "sportscourt": "Sports court",
        "figure.run": "Runner",
        "heart": "Heart",
        "cross.case": "First aid",
        "leaf": "Leaf",
        "pawprint": "Paw print",
        "fork.knife": "Fork and knife",
        "cup.and.saucer": "Cup",
        "gift": "Gift",
        "person.2": "People",
        "envelope": "Envelope",
        "bubble.left.and.bubble.right": "Chat",
        "newspaper": "Newspaper",
        "globe": "Globe",
        "star": "Star",
        "flag": "Flag",
        "lightbulb": "Light bulb",
        "lock": "Lock",
        "moon": "Moon",
    ]
}

extension WorkspaceList {
    /// The `move(from:to:)` arguments for dropping workspace `dragged` onto workspace `target`: it takes the
    /// target's place, and a drop onto Default lands just after it. Nil when `dragged` is Default, either is not
    /// listed, or nothing would move.
    public func reorder(dragging dragged: UUID, onto target: UUID) -> (from: Int, to: Int)? {
        guard let from = workspaces.firstIndex(where: { $0.id == dragged }), from != 0,
            let index = workspaces.firstIndex(where: { $0.id == target })
        else { return nil }
        let to = Swift.max(index, 1)
        return to == from ? nil : (from, to)
    }
}
