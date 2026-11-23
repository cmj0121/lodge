public enum ShortcutID: String, CaseIterable, Sendable {
    case newTab, newWindow, closeTab, openLocation, reload, find, bookmarkTab, toggleDownloads, zoomIn, zoomOut,
        actualSize, shortcutHelp, workspace1, workspace2, workspace3, workspace4, workspace5, workspace6, workspace7,
        workspace8, workspace9, pin1, pin2, pin3, pin4, pin5, pin6, pin7, pin8, pin9
}

extension ShortcutID {
    /// ⌃1 is Default, ⌃2–⌃9 the next eight workspaces in order.
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

    /// ⌘1–⌘9 open the sidebar's first nine pins in order, the shared Default pins when pins are shared.
    public static let pinSlots: [ShortcutID] = [.pin1, .pin2, .pin3, .pin4, .pin5, .pin6, .pin7, .pin8, .pin9]

    /// 1…9 for a pin slot, nil for every other shortcut.
    public var pinSlot: Int? {
        Self.pinSlots.firstIndex(of: self).map { $0 + 1 }
    }

    public static func pin(slot: Int) -> ShortcutID? {
        pinSlots.indices.contains(slot - 1) ? pinSlots[slot - 1] : nil
    }
}

/// Menu groups, in the order the overlay shows them.
public enum ShortcutMenu: String, CaseIterable, Sendable {
    case file = "File", edit = "Edit", view = "View", bookmarks = "Bookmarks", workspaces = "Workspaces",
        help = "Help"

    /// The group's heading in the overlay.
    public var title: String {
        switch self {
        case .file: String(localized: "File", bundle: .module)
        case .edit: String(localized: "Edit", bundle: .module)
        case .view: String(localized: "View", bundle: .module)
        case .bookmarks: String(localized: "Bookmarks", bundle: .module)
        case .workspaces: String(localized: "Workspaces", bundle: .module)
        case .help: String(localized: "Help", bundle: .module)
        }
    }
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
        Shortcut(.newTab, String(localized: "New Tab", bundle: .module), .file, KeyCombo("t")),
        Shortcut(.newWindow, String(localized: "New Window", bundle: .module), .file, KeyCombo("n")),
        Shortcut(.closeTab, String(localized: "Close Tab", bundle: .module), .file, KeyCombo("w")),
        Shortcut(.openLocation, String(localized: "Open Location…", bundle: .module), .file, KeyCombo("l")),
        Shortcut(.reload, String(localized: "Reload Page", bundle: .module), .view, KeyCombo("r")),
        Shortcut(.find, String(localized: "Find…", bundle: .module), .edit, KeyCombo("f")),
        Shortcut(.bookmarkTab, String(localized: "Bookmark This Tab", bundle: .module), .bookmarks, KeyCombo("d")),
        Shortcut(.toggleDownloads, String(localized: "Show Downloads", bundle: .module), .view, KeyCombo("j")),
        Shortcut(
            .zoomIn, String(localized: "Zoom In", bundle: .module), .view, KeyCombo("="), aliases: [KeyCombo("+")]),
        Shortcut(.zoomOut, String(localized: "Zoom Out", bundle: .module), .view, KeyCombo("-")),
        Shortcut(.actualSize, String(localized: "Actual Size", bundle: .module), .view, KeyCombo("0")),
        Shortcut(
            .shortcutHelp, String(localized: "Keyboard Shortcuts", bundle: .module), .help, KeyCombo("/"),
            yieldsToPage: true, note: String(localized: "outside the page", bundle: .module)),
    ]
        + ShortcutID.workspaceSlots.enumerated().map { index, id in
            let slot = index + 1
            return Shortcut(
                id, String(localized: "Workspace \(slot)", bundle: .module), .workspaces,
                KeyCombo(Character("\(slot)"), .control),
                note: slot == 1 ? String(localized: "⌃2–⌃9 next", bundle: .module) : nil, isListed: slot == 1)
        }
        + ShortcutID.pinSlots.enumerated().map { index, id in
            let slot = index + 1
            return Shortcut(
                id, String(localized: "Pin \(slot)", bundle: .module), .bookmarks, KeyCombo(Character("\(slot)")),
                note: slot == 1 ? String(localized: "⌘2–⌘9 next", bundle: .module) : nil, isListed: slot == 1)
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
