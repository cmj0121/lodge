import AppKit
import LodgeKit
import SwiftUI

extension WorkspaceColor {
    /// The swatch as a system colour, so it follows light and dark like the rest of the window.
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .graphite: Color(nsColor: Self.graphite)
        }
    }

    /// System grey taken a step darker, resolved per appearance.
    private static let graphite = NSColor(name: nil) { _ in
        NSColor.systemGray.blended(withFraction: 0.3, of: .black) ?? .systemGray
    }

    /// How strongly the swatch washes the window behind the sidebar: pale or low-contrast swatches (yellow, orange,
    /// teal) need more to show at all, deep ones less so they never fight the text.
    func washOpacity(in scheme: ColorScheme) -> Double {
        switch (self, scheme) {
        case (.red, .light): 0.08
        case (.red, _): 0.13
        case (.orange, .light): 0.12
        case (.orange, _): 0.13
        case (.yellow, .light): 0.17
        case (.yellow, _): 0.11
        case (.green, .light): 0.10
        case (.green, _): 0.12
        case (.teal, .light): 0.13
        case (.teal, _): 0.13
        case (.blue, .light): 0.08
        case (.blue, _): 0.15
        case (.purple, .light): 0.08
        case (.purple, _): 0.16
        case (.pink, .light): 0.09
        case (.pink, _): 0.13
        case (.graphite, .light): 0.10
        case (.graphite, _): 0.18
        }
    }

    /// The hairline round the selected row or tile.
    func strokeOpacity(in scheme: ColorScheme) -> Double {
        switch (self, scheme) {
        case (.yellow, .light): 0.9
        case (.graphite, .dark): 0.9
        case (_, .light): 0.6
        default: 0.7
        }
    }
}

extension EnvironmentValues {
    /// The colour of the workspace a browser window shows; nil leaves everything in the system look.
    @Entry var workspaceTint: WorkspaceColor?
}

extension View {
    func workspaceTint(_ tint: WorkspaceColor?) -> some View {
        environment(\.workspaceTint, tint)
    }
}

/// The workspace's wash over the window's ground; clear without a colour.
struct WorkspaceWash: View {
    @Environment(\.workspaceTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let tint {
            tint.color.opacity(tint.washOpacity(in: scheme))
        } else {
            Color.clear
        }
    }
}
