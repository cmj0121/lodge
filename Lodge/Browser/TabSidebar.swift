import LodgeKit
import SwiftUI

extension SidebarMode {
    /// Column width in points; the rail is just wide enough for the window buttons over its top.
    var width: CGFloat { self == .expanded ? 240 : 72 }

    /// Point size of the rail's symbol buttons, matched to its 24 pt item icons.
    static let railSymbolSize: CGFloat = 19
}

/// The left column: the full control sidebar, or the icon-only rail.
struct TabSidebar: View {
    let model: BrowserModel
    let mode: SidebarMode
    let toggle: () -> Void
    @Environment(WorkspaceCoordinator.self) private var coordinator

    var body: some View {
        switch mode {
        case .expanded: ExpandedSidebar(model: model, coordinator: coordinator, toggle: toggle)
        case .rail: RailSidebar(model: model, coordinator: coordinator, toggle: toggle)
        }
    }
}

/// Navigation beside the window buttons, the address, pins, the workspace's bookmarks and loose
/// tabs, and the workspace bar with Downloads.
private struct ExpandedSidebar: View {
    let model: BrowserModel
    let coordinator: WorkspaceCoordinator
    let toggle: () -> Void

    var body: some View {
        let items = model.sidebar
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SidebarToggle(isRail: false, action: toggle)
                Spacer(minLength: 0)
                NavigationButtons(model: model)
            }
            .frame(height: 32)
            // Clears the window buttons, which sit over this row.
            .padding(.leading, 78 - 12)
            AddressBar(model: model)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !items.pins.isEmpty {
                        Divider()
                        PinGrid(model: model, items: items.pins)
                            .padding(.vertical, 10)
                    }
                    Divider()
                    HStack {
                        WorkspaceHeader(workspace: coordinator.activeWorkspace)
                        Spacer(minLength: 0)
                        NewTabButton(model: model)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .contentShape(.rect)
                    .contextMenu {
                        Button("New Folder…") { BookmarkPrompts.newFolder(in: nil, model: model) }
                    }
                    if !items.bookmarks.isEmpty {
                        BookmarkOutline(model: model, nodes: items.bookmarks)
                    }
                    if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    rows(items.loose)
                }
            }
            .scrollIndicators(.never)
            Divider()
            HStack(spacing: 6) {
                WorkspaceBar(coordinator: coordinator, axis: .horizontal)
                ShortcutHelpButton(model: model, isRail: false)
                if let downloads = model.downloads {
                    DownloadsButton(model: model, manager: downloads, isRail: false)
                        .padding(.trailing, 4)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func rows(_ items: [SidebarItem]) -> some View {
        let selected = model.tabs.selectedID
        return ForEach(items) {
            SidebarRow(model: model, item: $0, isSelected: $0.isSelected(selected), favicon: model.favicon(for: $0))
        }
    }
}

extension SidebarNode {
    /// The node's bookmarks, depth-first through every folder, open or closed.
    fileprivate var bookmarkItems: [SidebarItem] {
        switch self {
        case .folder(_, _, _, let children): children.flatMap(\.bookmarkItems)
        case .item(let item): [item]
        }
    }
}

/// Icons only: expand, pins, the bookmarks menu, and the workspace bar with Downloads.
private struct RailSidebar: View {
    let model: BrowserModel
    let coordinator: WorkspaceCoordinator
    let toggle: () -> Void

    var body: some View {
        let items = model.sidebar
        let selected = model.tabs.selectedID
        VStack(spacing: 8) {
            SidebarToggle(isRail: true, action: toggle)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items.pins) {
                        ItemButton(
                            model: model, item: $0, isSelected: $0.isSelected(selected),
                            favicon: model.favicon(for: $0), shape: .rail)
                    }
                    if !items.bookmarks.isEmpty || !items.loose.isEmpty {
                        BookmarksMenu(model: model, items: items)
                    }
                }
            }
            .scrollIndicators(.never)
            VStack(spacing: 12) {
                WorkspaceBar(coordinator: coordinator, axis: .vertical)
                ShortcutHelpButton(model: model, isRail: true)
                if let downloads = model.downloads {
                    DownloadsButton(model: model, manager: downloads, isRail: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// The rail's stand-in for the bookmark and loose tab rows: one button whose menu lists them, each
/// folder as a submenu, filled while one of them is selected.
private struct BookmarksMenu: View {
    let model: BrowserModel
    let items: SidebarSections
    @State private var isHovered = false

    var body: some View {
        let selected = model.tabs.selectedID
        let isSelected = (items.bookmarks.flatMap(\.bookmarkItems) + items.loose).contains { $0.isSelected(selected) }
        let shape = ItemButton.Metrics.rail
        Menu {
            BookmarkMenuEntries(model: model, nodes: items.bookmarks, selected: selected)
            if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                Divider()
            }
            ForEach(items.loose) { MenuEntry(model: model, item: $0, selected: selected) }
        } label: {
            Image(systemName: isSelected ? "book.fill" : "book")
                .font(.system(size: SidebarMode.railSymbolSize))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: shape.width, height: shape.height)
                .background(rowBackground(isSelected: isSelected, isHovered: isHovered, cornerRadius: shape.cornerRadius))
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Bookmarks")
        .accessibilityLabel("Bookmarks")
        .accessibilityValue(isSelected ? "Open" : "")
    }
}

/// The bookmarks menu's entries for `nodes`: a bookmark as a checkable entry, a folder as a submenu.
private struct BookmarkMenuEntries: View {
    let model: BrowserModel
    let nodes: [SidebarNode]
    let selected: TabID?

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .folder(_, let title, _, let children):
                Menu {
                    if children.isEmpty {
                        Button("No Bookmarks") {}
                            .disabled(true)
                    }
                    BookmarkMenuEntries(model: model, nodes: children, selected: selected)
                } label: {
                    Label(title, systemImage: "folder")
                }
            case .item(let item):
                MenuEntry(model: model, item: item, selected: selected)
            }
        }
    }
}

/// One bookmark or loose tab in the bookmarks menu, checked while its tab is selected.
private struct MenuEntry: View {
    let model: BrowserModel
    let item: SidebarItem
    let selected: TabID?

    var body: some View {
        Toggle(
            isOn: Binding(get: { item.isSelected(selected) }, set: { _ in model.activate(item.target) })
        ) {
            Label {
                Text(item.title)
            } icon: {
                MenuIcon(content: IconContent(item: item, favicon: model.favicon(for: item)))
            }
        }
    }
}

/// An item's icon in the bookmarks menu. A menu draws only plain images, at their own size and
/// with no spinner, so the favicon and letter tile are drawn into small images once each, and an
/// hourglass stands in for loading.
private struct MenuIcon: View {
    let content: IconContent

    var body: some View {
        switch content {
        case .crashed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .loading:
            Image(systemName: "hourglass")
        case .favicon(let image):
            if let image = MenuImages.favicon(image) { Image(nsImage: image) }
        case .symbol(let name):
            Image(systemName: name)
        case .letter(let letter):
            if let image = MenuImages.letter(letter) { Image(nsImage: image) }
        }
    }
}

/// Menu-sized icon images, kept while memory allows: favicons by image, letter tiles by letter.
@MainActor
private enum MenuImages {
    private static let favicons = NSCache<NSImage, NSImage>()
    private static let letters = NSCache<NSString, NSImage>()

    static func favicon(_ favicon: NSImage) -> NSImage? {
        if let cached = favicons.object(forKey: favicon) { return cached }
        let image = render(Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit))
        if let image { favicons.setObject(image, forKey: favicon) }
        return image
    }

    /// A template image, so the menu tints the tile for its own appearance.
    static func letter(_ letter: String) -> NSImage? {
        if let cached = letters.object(forKey: letter as NSString) { return cached }
        let image = render(LetterIcon(letter: letter, size: menuIconSize, isOnTile: false).opacity(0.7))
        image?.isTemplate = true
        if let image { letters.setObject(image, forKey: letter as NSString) }
        return image
    }

    private static let menuIconSize: CGFloat = 16

    private static func render(_ view: some View) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: menuIconSize, height: menuIconSize))
        renderer.scale = 2
        return renderer.nsImage
    }
}

extension BrowserModel {
    fileprivate func favicon(for item: SidebarItem) -> NSImage? {
        item.tab.flatMap { favicons[$0.id] }
    }
}

/// Open, Pin, Bookmark, Unpin or Remove, and Close, as fit the item.
private struct ItemMenu: View {
    let model: BrowserModel
    let item: SidebarItem

    var body: some View {
        switch item {
        case .link(let link, let shelf, let tab):
            if shelf == .pins && tab == nil {
                Button("Open") { model.openLink(link) }
            }
            Button(shelf == .pins ? "Unpin" : "Remove from Bookmarks") { model.removeLink(link.id) }
        case .tab(let tab):
            Button("Pin Tab") { model.addLink(.pins, from: tab.id) }
                .disabled(!model.canAddLink(from: tab.id))
            Button("Bookmark Tab") { model.addLink(.bookmarks, from: tab.id) }
                .disabled(!model.canAddLink(from: tab.id))
        }
        if let tab = item.tab {
            Divider()
            Button("Close Tab") { model.close(tab.id) }
        }
    }
}

extension View {
    /// Hover tracking and the item's context menu, shared by every sidebar entry.
    fileprivate func sidebarItem(_ item: SidebarItem, model: BrowserModel, isHovered: Binding<Bool>) -> some View {
        onHover { isHovered.wrappedValue = $0 }
            .contextMenu { ItemMenu(model: model, item: item) }
    }

    /// An icon-only borderless button in the secondary colour, as the sidebar's small controls are.
    func iconButtonStyle() -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

/// What an item's icon shows, decided once for the sidebar and the rail's bookmarks menu: the
/// open tab's status, else the first letter of a link that is not open.
private enum IconContent {
    case crashed
    case loading
    case favicon(NSImage)
    case symbol(String)
    case letter(String)

    init(item: SidebarItem, favicon: NSImage?) {
        guard let tab = item.tab else {
            self = .letter(item.title.first.map { String($0).uppercased() } ?? "")
            return
        }
        if tab.hasCrashed {
            self = .crashed
        } else if tab.isLoading {
            self = .loading
        } else if let favicon {
            self = .favicon(favicon)
        } else {
            self = .symbol(tab.url == nil ? "square.dashed" : "globe")
        }
    }
}

/// The item's icon: the open tab's status, else a dimmed letter tile for a link that is not open.
private struct ItemIcon: View {
    let item: SidebarItem
    let image: NSImage?
    var size: CGFloat = 16
    var isOnTile = false

    var body: some View {
        Group {
            switch IconContent(item: item, favicon: image) {
            case .crashed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .loading:
                ProgressView()
                    .controlSize(.mini)
            case .favicon(let image):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            case .symbol(let name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
            case .letter(let letter):
                LetterIcon(letter: letter, size: size, isOnTile: isOnTile)
            }
        }
        .frame(width: size, height: size)
        .opacity(item.tab == nil ? 0.7 : 1)
    }
}

/// A link that is not open has no favicon yet: its first letter stands in, on a quiet tile of its
/// own unless it already sits on one.
struct LetterIcon: View {
    let letter: String
    let size: CGFloat
    let isOnTile: Bool

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(isOnTile ? 0 : 1), in: .rect(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}

/// The highlight under a row or tile: filled for the selected tab, faint on hover.
func rowBackground(isSelected: Bool, isHovered: Bool, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.primary.opacity(isSelected ? 0.12 : isHovered ? 0.05 : 0))
}

/// Pins as favicon tiles, four to a row.
private struct PinGrid: View {
    let model: BrowserModel
    let items: [SidebarItem]

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let selected = model.tabs.selectedID
        LazyVGrid(columns: Self.columns, spacing: 6) {
            ForEach(items) {
                ItemButton(
                    model: model, item: $0, isSelected: $0.isSelected(selected), favicon: model.favicon(for: $0),
                    shape: .pin)
            }
        }
    }
}

/// A pin as its icon alone, the title as a tooltip: a tile in the grid, or an entry in the rail.
/// Dragging it onto another pin moves it to that pin's place.
private struct ItemButton: View {
    struct Metrics {
        let iconSize: CGFloat
        /// Nil fills the width on offer.
        let width: CGFloat?
        let height: CGFloat
        let cornerRadius: CGFloat
        /// Whether the icon sits on a quiet tile of its own while not selected.
        let isTile: Bool

        static let pin = Metrics(iconSize: 18, width: nil, height: 40, cornerRadius: 9, isTile: true)
        static let rail = Metrics(iconSize: 24, width: 46, height: 40, cornerRadius: 10, isTile: false)
    }

    let model: BrowserModel
    let item: SidebarItem
    let isSelected: Bool
    let favicon: NSImage?
    let shape: Metrics
    @State private var isHovered = false

    var body: some View {
        Button {
            model.activate(item.target)
        } label: {
            ItemIcon(item: item, image: favicon, size: shape.iconSize, isOnTile: shape.isTile)
                .frame(maxWidth: shape.width ?? .infinity)
                .frame(width: shape.width, height: shape.height)
                .background(
                    .quaternary.opacity(shape.isTile && !isSelected ? 0.5 : 0), in: .rect(cornerRadius: shape.cornerRadius)
                )
                .background(rowBackground(isSelected: isSelected, isHovered: isHovered, cornerRadius: shape.cornerRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityActions {
            // The grid runs left to right, the rail top to bottom.
            Button(shape.isTile ? "Move Left" : "Move Up") { move(by: -1) }
            Button(shape.isTile ? "Move Right" : "Move Down") { move(by: 1) }
        }
        .sidebarItem(item, model: model, isHovered: $isHovered)
        .modifier(PinDrag(pin: pinID))
        .dropDestination(for: String.self) { payload, _ in
            guard let dragged = payload.first.flatMap(UUID.init(uuidString:)), isPin(dragged), let index else {
                return false
            }
            model.movePin(dragged, to: index)
            return true
        } isTargeted: {
            isHovered = $0
        }
    }

    private var pinID: UUID? {
        if case .link(let link, .pins, _) = item { link.id } else { nil }
    }

    /// This pin's place among the pins.
    private var index: Int? { model.sidebar.pins.firstIndex { $0.id == item.id } }

    /// Whether a dropped id is a pin's, so a bookmark or stray text moves nothing.
    private func isPin(_ id: UUID) -> Bool { model.sidebar.pins.contains { $0.id == .link(id) } }

    private func move(by offset: Int) {
        if let pinID, let index { model.movePin(pinID, to: index + offset) }
    }
}

/// Lets a pin be dragged, carrying its link id; anything else stays put.
private struct PinDrag: ViewModifier {
    let pin: UUID?

    func body(content: Content) -> some View {
        if let pin {
            content.draggable(pin.uuidString)
        } else {
            content
        }
    }
}

/// A loose tab with its title; the selected one carries a close button.
private struct SidebarRow: View {
    let model: BrowserModel
    let item: SidebarItem
    let isSelected: Bool
    let favicon: NSImage?
    @State private var isHovered = false

    var body: some View {
        SidebarRowLabel(model: model, item: item, isSelected: isSelected, isHovered: isHovered, favicon: favicon)
            .contentShape(.rect)
            .onTapGesture { model.activate(item.target) }
            .help(item.address)
            .itemAccessibility(item, isSelected: isSelected, model: model)
            .sidebarItem(item, model: model, isHovered: $isHovered)
    }
}

/// A row of the bookmark tree: a bookmark drawn as the sidebar's other rows are, or a folder with its
/// disclosure chevron, set in by its depth. The outline beneath takes its clicks, drags, menu, tooltip
/// and accessibility.
struct BookmarkTreeRow: View {
    let model: BrowserModel
    let rows: BookmarkRows
    let id: SidebarItem.ID

    var body: some View {
        let isHovered = rows.hovered == id
        Group {
            switch rows.nodes[id] {
            case .folder(_, let title, let isExpanded, _)?:
                FolderRowLabel(title: title, isExpanded: isExpanded, isHovered: isHovered)
            case .item(let item)?:
                SidebarRowLabel(
                    model: model, item: item, isSelected: item.isSelected(model.tabs.selectedID), isHovered: isHovered,
                    favicon: model.favicon(for: item))
            case nil:
                EmptyView()
            }
        }
        .padding(.leading, CGFloat(rows.depths[id] ?? 0) * BookmarkOutline.indent)
        // The outline's row view is the row's one accessibility element.
        .accessibilityHidden(true)
    }
}

/// A folder's look in the tree: its icon, title, and a chevron that turns down while it is open.
private struct FolderRowLabel: View {
    let title: String
    let isExpanded: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: SidebarRowLabel.Metrics.iconSize, height: SidebarRowLabel.Metrics.iconSize)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.snappy(duration: 0.2), value: isExpanded)
                .frame(width: SidebarRowLabel.Metrics.iconSize, height: SidebarRowLabel.Metrics.iconSize)
        }
        .padding(.horizontal, SidebarRowLabel.Metrics.padding)
        .frame(height: SidebarRowLabel.Metrics.height)
        .background(
            rowBackground(isSelected: false, isHovered: isHovered, cornerRadius: SidebarRowLabel.Metrics.cornerRadius))
    }
}

/// A bookmark or loose tab's look: icon, title, and a close button while it is open and hovered or selected.
struct SidebarRowLabel: View {
    /// Row geometry, shared with the bookmark tree's folder rows and its close-button hit area.
    enum Metrics {
        static let height: CGFloat = 30
        /// Inset of the icon and the close button from the row's edges.
        static let padding: CGFloat = 8
        /// Side of the icon and of the close button.
        static let iconSize: CGFloat = 16
        static let cornerRadius: CGFloat = 7
    }

    let model: BrowserModel
    let item: SidebarItem
    let isSelected: Bool
    let isHovered: Bool
    let favicon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(item: item, image: favicon)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(item.tab == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tab = item.tab {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovered || isSelected ? 1 : 0)
                .help(ShortcutCatalog.tooltip("Close tab", for: .closeTab))
                .accessibilityLabel("Close \(item.title)")
            }
        }
        .padding(.horizontal, Metrics.padding)
        .frame(height: Metrics.height)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered, cornerRadius: Metrics.cornerRadius))
    }
}

extension View {
    /// A bookmark or tab row as one accessibility button named by its title, activated by default and
    /// closable while its tab is open.
    fileprivate func itemAccessibility(_ item: SidebarItem, isSelected: Bool, model: BrowserModel) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.activate(item.target) }
            .accessibilityActions {
                if let tab = item.tab {
                    Button("Close Tab") { model.close(tab.id) }
                }
            }
    }
}

private struct SidebarToggle: View {
    let isRail: Bool
    let action: () -> Void

    var body: some View {
        let verb = isRail ? "Expand" : "Collapse"
        Button("\(verb) Sidebar", systemImage: "sidebar.left", action: action)
            .iconButtonStyle()
            .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
            .help("\(verb) the sidebar")
    }
}

/// Opens and closes the keyboard shortcut overlay, as Help ▸ Keyboard Shortcuts opens it (D3).
private struct ShortcutHelpButton: View {
    let model: BrowserModel
    let isRail: Bool

    var body: some View {
        Button("Keyboard Shortcuts", systemImage: "questionmark", action: model.toggleShortcutHelp)
            .iconButtonStyle()
            .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
            .help("Keyboard shortcuts")
            .accessibilityAddTraits(model.isShortcutHelpVisible ? .isSelected : [])
    }
}

/// The shown workspace's symbol and name over its bookmarks and tabs (D6).
private struct WorkspaceHeader: View {
    let workspace: Workspace

    var body: some View {
        Label {
            Text(workspace.name)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: workspace.symbol)
                .symbolVariant(.fill)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace: \(workspace.name)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NewTabButton: View {
    let model: BrowserModel

    var body: some View {
        Button("New Tab", systemImage: "plus", action: model.newTab)
            .iconButtonStyle()
            .help(ShortcutCatalog.tooltip("Open a new tab", for: .newTab))
    }
}
