import Foundation

/// A workspace's tint. `graphite` belongs to Anonymous alone and is not offered to the user.
public enum WorkspaceColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, graphite

    /// The swatches the workspace sheet offers, in order; no graphite.
    public static let palette: [WorkspaceColor] = [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink]

    /// The spoken name.
    public var label: String {
        switch self {
        case .red: String(localized: "Red", bundle: .module)
        case .orange: String(localized: "Orange", bundle: .module)
        case .yellow: String(localized: "Yellow", bundle: .module)
        case .green: String(localized: "Green", bundle: .module)
        case .teal: String(localized: "Teal", bundle: .module)
        case .blue: String(localized: "Blue", bundle: .module)
        case .purple: String(localized: "Purple", bundle: .module)
        case .pink: String(localized: "Pink", bundle: .module)
        case .graphite: String(localized: "Graphite", bundle: .module)
        }
    }
}
