public enum ShortcutID: String, CaseIterable, Sendable {
    case newTab, closeTab, openLocation, reload, find, bookmarkTab, toggleDownloads, zoomIn, zoomOut, actualSize,
        shortcutHelp, workspace1, workspace2, workspace3, workspace4, workspace5, workspace6, workspace7, workspace8,
        workspace9
}

extension ShortcutID {
    /// ⌘1 is Default, ⌘2–⌘9 the next eight workspaces in order.
    public static let workspaceSlots: [ShortcutID] = [
        .workspace1, .workspace2, .workspace3, .workspace4, .workspace5, .workspace6, .workspace7, .workspace8,
        .workspace9,
    ]

    /// 1…9 for a workspace slot, nil for every other shortcut.
    public var workspaceSlot: Int? {
        Self.workspaceSlots.firstIndex(of: self).map { $0 + 1 }
    }

    public static func workspace(slot: Int) -> ShortcutID? {
        workspaceSlots.indices.contains(slot - 1) ? workspaceSlots[slot - 1] : nil
    }
}

/// Menu groups, in the order the overlay shows them.
public enum ShortcutMenu: String, CaseIterable, Sendable {
    case file = "File", edit = "Edit", view = "View", bookmarks = "Bookmarks", workspaces = "Workspaces",
        help = "Help"
}

public struct KeyCombo: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public let key: Character
    public let modifiers: Modifiers

    public init(_ key: Character, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Glyphs in ⌃⌥⇧⌘ order, then the key, letters uppercased: "⌘T", "⌘=", "⌘+".
    public var display: String {
        let glyphs: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return glyphs.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
}

public struct Shortcut: Identifiable, Hashable, Sendable {
    public let id: ShortcutID
    public let title: String
    public let menu: ShortcutMenu
    public let combo: KeyCombo
    public let aliases: [KeyCombo]
    /// The page keeps the key while a web view has focus, so no menu item carries it (D10).
    public let yieldsToPage: Bool
    /// Shown beside the key in the overlay, e.g. "outside the page".
    public let note: String?
    /// False keeps the shortcut out of the overlay's `grouped`; its menu item still binds the key.
    public let isListed: Bool

    init(
        _ id: ShortcutID, _ title: String, _ menu: ShortcutMenu, _ combo: KeyCombo, aliases: [KeyCombo] = [],
        yieldsToPage: Bool = false, note: String? = nil, isListed: Bool = true
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.combo = combo
        self.aliases = aliases
        self.yieldsToPage = yieldsToPage
        self.note = note
        self.isListed = isListed
    }
}

public enum ShortcutCatalog {
    public static let all: [Shortcut] = [
        Shortcut(.newTab, "New Tab", .file, KeyCombo("t")),
        Shortcut(.closeTab, "Close Tab", .file, KeyCombo("w")),
        Shortcut(.openLocation, "Open Location…", .file, KeyCombo("l")),
        Shortcut(.reload, "Reload Page", .view, KeyCombo("r")),
        Shortcut(.find, "Find…", .edit, KeyCombo("f")),
        Shortcut(.bookmarkTab, "Bookmark This Tab", .bookmarks, KeyCombo("d")),
        Shortcut(.toggleDownloads, "Show Downloads", .view, KeyCombo("j")),
        Shortcut(.zoomIn, "Zoom In", .view, KeyCombo("="), aliases: [KeyCombo("+")]),
        Shortcut(.zoomOut, "Zoom Out", .view, KeyCombo("-")),
        Shortcut(.actualSize, "Actual Size", .view, KeyCombo("0")),
        Shortcut(.shortcutHelp, "Keyboard Shortcuts", .help, KeyCombo("/"), yieldsToPage: true, note: "outside the page"),
    ]
        + ShortcutID.workspaceSlots.enumerated().map { index, id in
            let slot = index + 1
            return Shortcut(
                id, "Workspace \(slot)", .workspaces, KeyCombo(Character("\(slot)")),
                note: slot == 1 ? "⌘2–⌘9 next" : nil, isListed: slot == 1)
        }

    public static subscript(id: ShortcutID) -> Shortcut {
        all.first { $0.id == id }!
    }

    public static var grouped: [(menu: ShortcutMenu, shortcuts: [Shortcut])] {
        ShortcutMenu.allCases.compactMap { menu in
            let shortcuts = all.filter { $0.menu == menu && $0.isListed }
            return shortcuts.isEmpty ? nil : (menu, shortcuts)
        }
    }

    /// "Open a new tab (⌘T)" — every tooltip that names a key goes through this.
    public static func tooltip(_ text: String, for id: ShortcutID) -> String {
        "\(text) (\(self[id].combo.display))"
    }
}
