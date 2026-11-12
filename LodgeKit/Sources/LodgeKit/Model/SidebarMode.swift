/// How the window's left column shows: the full control sidebar, or an icon-only rail.
public enum SidebarMode: String, Sendable, CaseIterable {
    case expanded
    case rail

    /// The user-defaults key the mode is kept under. The raw values are what is stored, so they
    /// must not change.
    public static let defaultsKey = "sidebarMode"

    public var toggled: SidebarMode { self == .expanded ? .rail : .expanded }
}
