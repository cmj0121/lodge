import Foundation

/// A workspace's tint. `graphite` belongs to Anonymous alone and is not offered to the user.
public enum WorkspaceColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, graphite

    /// The swatches the workspace sheet offers, in order; no graphite.
    public static let palette: [WorkspaceColor] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    /// The spoken name.
    public var label: String {
        switch self {
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .graphite: "Graphite"
        }
    }
}
