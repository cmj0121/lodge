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
    let pane: BrowserPane
    let mode: SidebarMode
    let toggle: () -> Void
    @Environment(WorkspaceCoordinator.self) private var coordinator

    var body: some View {
        switch mode {
        case .expanded: ExpandedSidebar(pane: pane, coordinator: coordinator, toggle: toggle)
        case .rail: RailSidebar(pane: pane, coordinator: coordinator, toggle: toggle)
        }
    }
}

/// Navigation beside the window buttons, the address, pins, the workspace's bookmarks and loose
/// tabs, and the workspace bar with Downloads.
private struct ExpandedSidebar: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let coordinator: WorkspaceCoordinator
    let toggle: () -> Void
    @State private var dragPresence = SidebarDragPresence()

    var body: some View {
        let items = model.sidebar
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SidebarToggle(isRail: false, action: toggle)
                Spacer(minLength: 0)
                NavigationButtons(pane: pane)
            }
            .frame(height: 32)
            // Clears the window buttons, which sit over this row.
            .padding(.leading, 78 - 12)
            AddressBar(pane: pane, isCompact: true)
                // With no pins, a drag shows where to pin over the address, so nothing below moves under the pointer.
                .overlay {
                    if items.pins.isEmpty && dragPresence.isDragging {
                        EmptyPinsDropZone(model: model)
                            .environment(\.sidebarDragPresence, dragPresence)
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !items.pins.isEmpty {
                        Divider()
                        PinGrid(pane: pane, items: items.pins)
                            .padding(.vertical, 10)
                    }
                    Divider()
                    HStack {
                        WorkspaceHeader(workspace: coordinator.activeWorkspace)
                        Spacer(minLength: 0)
                        NewTabButton(pane: pane)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .contentShape(.rect)
                    .contextMenu {
                        Button("New Folder…") { BookmarkPrompts.newFolder(in: nil, model: model) }
                    }
                    // A drop on the header goes into the bookmarks' root, the one place to drop on while there are none.
                    .sidebarDrop(model) { _, _, _ in
                        .bookmarks(folder: model.library.bookmarks.id, index: nil)
                    } indicator: { _, _ in
                        DropIntoMark(cornerRadius: SidebarRowLabel.Metrics.cornerRadius)
                    }
                    if !items.bookmarks.isEmpty {
                        BookmarkOutline(
                            pane: pane, workspaces: coordinator, nodes: items.bookmarks, dragPresence: dragPresence)
                    }
                    if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    rows(items.loose)
                    LooseDropEnd(model: model)
                }
            }
            .scrollIndicators(.never)
            .onDrop(of: [.lodgeSidebarItem], delegate: SidebarDragTracker(presence: dragPresence))
            .environment(\.sidebarDragPresence, dragPresence)
            Divider()
            HStack(spacing: 6) {
                WorkspaceBar(coordinator: coordinator, pane: pane, axis: .horizontal)
                ShortcutHelpButton(pane: pane, isRail: false)
                if let downloads = model.downloads {
                    DownloadsButton(window: pane.window, manager: downloads, isRail: false)
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
        let selected = pane.selectedID
        return ForEach(items) {
            SidebarRow(pane: pane, item: $0, isSelected: $0.isSelected(selected), favicon: model.favicon(for: $0))
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
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let coordinator: WorkspaceCoordinator
    let toggle: () -> Void

    var body: some View {
        let items = model.sidebar
        let selected = pane.selectedID
        VStack(spacing: 8) {
            SidebarToggle(isRail: true, action: toggle)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(items.pins) {
                        ItemButton(
                            pane: pane, item: $0, isSelected: $0.isSelected(selected),
                            favicon: model.favicon(for: $0), shape: .rail)
                    }
                    if !items.bookmarks.isEmpty || !items.loose.isEmpty {
                        BookmarksMenu(pane: pane, items: items)
                    }
                }
            }
            .scrollIndicators(.never)
            VStack(spacing: 12) {
                WorkspaceBar(coordinator: coordinator, pane: pane, axis: .vertical)
                ShortcutHelpButton(pane: pane, isRail: true)
                if let downloads = model.downloads {
                    DownloadsButton(window: pane.window, manager: downloads, isRail: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// The rail's stand-in for the bookmark and loose tab rows: one button whose menu lists them, each
/// folder as a submenu, filled while one of them is selected; below them, Move and Open in Workspace for each open tab.
private struct BookmarksMenu: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let items: SidebarSections
    @Environment(WorkspaceCoordinator.self) private var coordinator
    @State private var isHovered = false

    var body: some View {
        let selected = pane.selectedID
        let isSelected = (items.bookmarks.flatMap(\.bookmarkItems) + items.loose).contains { $0.isSelected(selected) }
        let shape = ItemButton.Metrics.rail
        Menu {
            BookmarkMenuEntries(pane: pane, nodes: items.bookmarks, selected: selected)
            if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                Divider()
            }
            ForEach(items.loose) { MenuEntry(pane: pane, item: $0, selected: selected) }
            let open = (items.bookmarks.flatMap(\.bookmarkItems) + items.loose).compactMap(\.tab)
            if !open.isEmpty {
                Divider()
                Menu("Move to Workspace") {
                    ForEach(open) { tab in
                        WorkspaceMenu(title: tab.displayTitle, tab: tab, from: model.workspaceID, coordinator: coordinator) {
                            coordinator.move(tab: tab.id, to: $0)
                        }
                    }
                }
                Menu("Open in Workspace") {
                    ForEach(open) { tab in
                        WorkspaceMenu(title: tab.displayTitle, tab: tab, from: model.workspaceID, coordinator: coordinator) {
                            coordinator.open(tab: tab.id, in: $0)
                        }
                    }
                }
            }
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
        .accessibilityValue(isSelected ? String(localized: "Open") : "")
    }
}

/// The bookmarks menu's entries for `nodes`: a bookmark as a checkable entry, a folder as a submenu.
private struct BookmarkMenuEntries: View {
    let pane: BrowserPane
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
                    BookmarkMenuEntries(pane: pane, nodes: children, selected: selected)
                } label: {
                    Label(title, systemImage: "folder")
                }
            case .item(let item):
                MenuEntry(pane: pane, item: item, selected: selected)
            }
        }
    }
}

/// One bookmark or loose tab in the bookmarks menu, checked while its tab is selected.
private struct MenuEntry: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let item: SidebarItem
    let selected: TabID?

    var body: some View {
        Toggle(
            isOn: Binding(get: { item.isSelected(selected) }, set: { _ in pane.activate(item.target) })
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

/// Open, Pin, Bookmark, Unpin or Remove, and Close, as fit the item.
private struct ItemMenu: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let item: SidebarItem
    @Environment(WorkspaceCoordinator.self) private var coordinator

    var body: some View {
        switch item {
        case .link(let link, let shelf, let tab):
            if shelf == .pins && tab == nil {
                Button("Open") { pane.activate(.link(link)) }
            }
            if shelf == .pins {
                Button("Unpin") { model.unpin(link.id) }
                let move = SidebarDragItem(kind: .pin, id: link.id, workspace: model.workspaceID)
                let bookmarks = SidebarDropTarget.bookmarks(folder: model.library.bookmarks.id, index: nil)
                Button("Move to Bookmarks") { model.drop(move, on: bookmarks) }
                    .disabled(!model.canDrop(move, on: bookmarks))
            } else {
                Button("Remove from Bookmarks") { model.removeLink(link.id) }
            }
        case .tab(let tab):
            Button("Pin Tab") { model.addLink(.pins, from: tab.id) }
                .disabled(!model.canAddLink(from: tab.id))
            Button("Bookmark Tab") { model.addLink(.bookmarks, from: tab.id) }
                .disabled(!model.canAddLink(from: tab.id))
        }
        if let tab = item.tab {
            WorkspaceMenu(title: String(localized: "Move to Workspace"), tab: tab, from: model.workspaceID, coordinator: coordinator) {
                coordinator.move(tab: tab.id, to: $0)
            }
            WorkspaceMenu(title: String(localized: "Open in Workspace"), tab: tab, from: model.workspaceID, coordinator: coordinator) {
                coordinator.open(tab: tab.id, in: $0)
            }
            Divider()
            Button("Close Tab") { pane.close(tab.id) }
        }
    }
}

/// A submenu of every other workspace, each with its icon; disabled for a tab with no address.
private struct WorkspaceMenu: View {
    let title: String
    let tab: BrowserTab
    let from: UUID
    let coordinator: WorkspaceCoordinator
    let action: (UUID) -> Void

    var body: some View {
        Menu(title) {
            ForEach(coordinator.destinations(from: from)) { workspace in
                Button {
                    action(workspace.id)
                } label: {
                    Label { Text(workspace.name) } icon: { Image(systemName: workspace.symbol) }
                }
            }
        }
        .disabled(tab.url == nil)
    }
}

extension View {
    /// Hover tracking and the item's context menu, shared by every sidebar entry.
    fileprivate func sidebarItem(_ item: SidebarItem, pane: BrowserPane, isHovered: Binding<Bool>) -> some View {
        onHover { isHovered.wrappedValue = $0 }
            .contextMenu { ItemMenu(pane: pane, item: item) }
    }

    /// An icon-only borderless button in the secondary colour, as the sidebar's small controls are.
    func iconButtonStyle() -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

/// What an item's icon shows, decided once for the sidebar and the rail's bookmarks menu: the
/// open tab's status, else a link's kept icon (a shared pin's, an Anonymous bookmark's) or its first letter.
private enum IconContent {
    case crashed
    case loading
    case favicon(NSImage)
    case symbol(String)
    case letter(String)

    init(item: SidebarItem, favicon: NSImage?) {
        guard let tab = item.tab else {
            if let favicon {
                self = .favicon(favicon)
            } else if case .link(let link, _, _) = item, let page = LodgePage(url: link.url) {
                self = .symbol(page.symbol)
            } else {
                self = .letter(item.title.first.map { String($0).uppercased() } ?? "")
            }
            return
        }
        if tab.hasCrashed {
            self = .crashed
        } else if tab.isLoading {
            self = .loading
        } else if let favicon {
            self = .favicon(favicon)
        } else {
            self = .symbol(tab.lodgePage?.symbol ?? (tab.url == nil ? "square.dashed" : "globe"))
        }
    }
}

/// The item's icon: the open tab's status; a link that is not open shows, dimmed, its kept icon (a shared pin's
/// from Default, or an Anonymous bookmark's stored one), else the letter tile.
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
        .opacity(item.tab == nil ? 0.7 : item.tab?.isResting == true ? 0.5 : 1)
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
    RowBackground(isSelected: isSelected, isHovered: isHovered, cornerRadius: cornerRadius)
}

/// The fill stays primary-based so selected and hovered read apart on any tint; a coloured workspace adds a
/// hairline in its colour round the selected one.
private struct RowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let cornerRadius: CGFloat
    @Environment(\.workspaceTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(Color.primary.opacity(isSelected ? 0.12 : isHovered ? 0.05 : 0))
            .overlay {
                if isSelected, let tint {
                    shape.strokeBorder(tint.color.opacity(tint.strokeOpacity(in: scheme)), lineWidth: 1)
                }
            }
    }
}

/// Pins as favicon tiles, four to a row.
private struct PinGrid: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let items: [SidebarItem]

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        let selected = pane.selectedID
        LazyVGrid(columns: Self.columns, spacing: 6) {
            ForEach(items) {
                ItemButton(
                    pane: pane, item: $0, isSelected: $0.isSelected(selected), favicon: model.favicon(for: $0),
                    shape: .pin)
            }
        }
    }
}

/// A pin as its icon alone, the title as a tooltip: a tile in the grid, or an entry in the rail. It drags as a
/// sidebar item, and takes drops before or after itself, whichever half the pointer is on (D4).
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

    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let item: SidebarItem
    let isSelected: Bool
    let favicon: NSImage?
    let shape: Metrics
    @State private var isHovered = false

    var body: some View {
        Button {
            pane.activate(item.target)
        } label: {
            ItemIcon(item: item, image: favicon, size: shape.iconSize, isOnTile: shape.isTile)
                .frame(maxWidth: shape.width ?? .infinity)
                .frame(width: shape.width, height: shape.height)
                .overlay(alignment: .topTrailing) {
                    if pane.isShownElsewhere(item) {
                        ShownElsewhereMark(size: 8)
                            .padding(4)
                    }
                }
                .background(
                    .quaternary.opacity(shape.isTile && !isSelected ? 0.5 : 0), in: .rect(cornerRadius: shape.cornerRadius)
                )
                .background(rowBackground(isSelected: isSelected, isHovered: isHovered, cornerRadius: shape.cornerRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(pane.note(for: item).map { "\(item.title)\n\($0)" } ?? item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(pane.note(for: item) ?? "")
        .accessibilityActions {
            // The grid runs left to right, the rail top to bottom.
            Button(shape.isTile ? "Move Left" : "Move Up") { move(by: -1) }
            Button(shape.isTile ? "Move Right" : "Move Down") { move(by: 1) }
        }
        .sidebarItem(item, pane: pane, isHovered: $isHovered)
        .sidebarDrag(pinID.map { SidebarDragItem(kind: .pin, id: $0, workspace: model.workspaceID) })
        .sidebarDrop(model, target: target) { location, size in
            let isAfter = isAfter(location, in: size)
            if shape.isTile {
                DropPlaceMark(axis: .vertical)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: isAfter ? .trailing : .leading)
                    .offset(x: isAfter ? Self.markOffset(gap: 6) : -Self.markOffset(gap: 6))
            } else {
                DropPlaceMark(axis: .horizontal)
                    .padding(.horizontal, 4)
                    .frame(maxHeight: .infinity, alignment: isAfter ? .bottom : .top)
                    .offset(y: isAfter ? Self.markOffset(gap: 4) : -Self.markOffset(gap: 4))
            }
        }
    }

    /// How far the mark moves out from the tile's edge so it sits in the middle of the `gap` to the next one.
    private static func markOffset(gap: CGFloat) -> CGFloat { 3 + gap / 2 }

    /// Whether the pointer is on the half of the tile after its middle: the right in the grid, the bottom in the rail.
    private func isAfter(_ location: CGPoint, in size: CGSize) -> Bool {
        shape.isTile ? location.x > size.width / 2 : location.y > size.height / 2
    }

    /// The slot the pointer marks, before or after this pin; a pin moved forward ends one place earlier, as it leaves
    /// its own slot behind.
    private func target(_ dragged: SidebarDragItem, _ location: CGPoint, _ size: CGSize) -> SidebarDropTarget? {
        guard let index else { return nil }
        var slot = index + (isAfter(location, in: size) ? 1 : 0)
        if dragged.kind == .pin, let from = model.sidebar.pins.firstIndex(where: { $0.id == .link(dragged.id) }) {
            if from == index { return nil }
            if from < slot { slot -= 1 }
        }
        return .pins(index: slot)
    }

    private var pinID: UUID? {
        if case .link(let link, .pins, _) = item { link.id } else { nil }
    }

    /// This pin's place among the pins.
    private var index: Int? { model.sidebar.pins.firstIndex { $0.id == item.id } }

    private func move(by offset: Int) {
        if let pinID, let index { model.movePin(pinID, to: index + offset) }
    }
}

/// A loose tab with its title; the selected one carries a close button. It drags as a sidebar item, and a drop on it
/// lands just above it (D4); Move Up and Move Down do the same from the keyboard.
private struct SidebarRow: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
    let item: SidebarItem
    let isSelected: Bool
    let favicon: NSImage?
    @State private var isHovered = false

    var body: some View {
        SidebarRowLabel(pane: pane, item: item, isSelected: isSelected, isHovered: isHovered, favicon: favicon)
            .contentShape(.rect)
            .onTapGesture { pane.activate(item.target) }
            .help(pane.toolTip(for: item))
            .itemAccessibility(item, isSelected: isSelected, pane: pane)
            .accessibilityActions {
                if let up = place(by: -1) { Button("Move Up") { move(to: up) } }
                if let down = place(by: 1) { Button("Move Down") { move(to: down) } }
            }
            .sidebarItem(item, pane: pane, isHovered: $isHovered)
            .sidebarDrag(dragItem)
            .sidebarDrop(model) { dragged, _, _ in
                guard let tab = item.tab, dragged != dragItem else { return nil }
                return .loose(before: tab.id)
            } indicator: { _, _ in
                LooseDropMark()
            }
    }

    private var dragItem: SidebarDragItem? {
        item.tab.map { SidebarDragItem(kind: .tab, id: $0.id, workspace: model.workspaceID) }
    }

    /// Where moving the row `offset` places among the loose tabs puts it; nil past either end.
    private func place(by offset: Int) -> SidebarDropTarget? {
        let loose = model.sidebar.loose.compactMap(\.tab?.id)
        guard let tab = item.tab, let index = loose.firstIndex(of: tab.id) else { return nil }
        let to = index + offset
        guard loose.indices.contains(to) else { return nil }
        // Moving down lands before the tab after the next one, or at the end.
        let before = offset < 0 ? to : to + 1
        return .loose(before: before < loose.count ? loose[before] : nil)
    }

    private func move(to place: SidebarDropTarget) {
        if let dragItem { model.drop(dragItem, on: place) }
    }
}

/// The line above a loose row a drop lands before, in the middle of the gap to the row above.
private struct LooseDropMark: View {
    var body: some View {
        DropPlaceMark(axis: .horizontal)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: -4)
    }
}

/// The place after the last loose tab, and the only one while there are none: a drop here lands at the end.
private struct LooseDropEnd: View {
    let model: BrowserModel

    var body: some View {
        Color.clear
            .frame(height: 24)
            .contentShape(.rect)
            .sidebarDrop(model) { _, _, _ in .loose(before: nil) } indicator: { _, _ in LooseDropMark() }
            .accessibilityHidden(true)
    }
}

/// A row of the bookmark tree: a bookmark drawn as the sidebar's other rows are, or a folder with its
/// disclosure chevron, set in by its depth. The outline beneath takes its clicks, drags, menu, tooltip
/// and accessibility.
struct BookmarkTreeRow: View {
    let pane: BrowserPane
    private var model: BrowserModel { pane.model }
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
                    pane: pane, item: item, isSelected: item.isSelected(pane.selectedID), isHovered: isHovered,
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

    let pane: BrowserPane
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
                .foregroundStyle(item.tab == nil || item.tab?.isResting == true ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tab = item.tab {
                let showsClose = isHovered || isSelected
                // The mark holds the close button's place until the pointer brings the button up over it.
                ZStack {
                    if pane.isShownElsewhere(tab.id) {
                        ShownElsewhereMark()
                            .opacity(showsClose ? 0 : 1)
                    }
                    Button {
                        pane.close(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(showsClose ? 1 : 0)
                    .help(ShortcutCatalog.tooltip(String(localized: "Close tab"), for: .closeTab))
                    .accessibilityLabel("Close \(item.title)")
                }
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
    fileprivate func itemAccessibility(_ item: SidebarItem, isSelected: Bool, pane: BrowserPane) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityValue(pane.note(for: item) ?? "")
            .accessibilityAction { pane.activate(item.target) }
            .accessibilityActions {
                if let tab = item.tab {
                    Button("Close Tab") { pane.close(tab.id) }
                }
            }
    }
}

/// Marks a row or tile whose tab another window shows, where a click brings that window forward (D4): a small
/// window glyph in the quietest label colour, so it reads in light and dark without competing with the title.
struct ShownElsewhereMark: View {
    static let hint = String(localized: "Shown in another window")

    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "macwindow")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

extension BrowserPane {
    /// Whether another window shows the item's open tab.
    func isShownElsewhere(_ item: SidebarItem) -> Bool {
        item.tab.map { isShownElsewhere($0.id) } == true
    }

    /// What a row's tooltip and accessibility value add to its title: that another window shows its tab, or that
    /// its tab rests and selecting it wakes it; nil when neither.
    func note(for item: SidebarItem) -> String? {
        if isShownElsewhere(item) { return ShownElsewhereMark.hint }
        return item.tab?.isResting == true ? Self.restingHint : nil
    }

    static let restingHint = String(localized: "Resting; selecting it wakes it")

    /// A bookmark or tab row's tooltip: its address, and its note when it has one.
    func toolTip(for item: SidebarItem) -> String {
        note(for: item).map { "\(item.address)\n\($0)" } ?? item.address
    }
}

private struct SidebarToggle: View {
    let isRail: Bool
    let action: () -> Void

    var body: some View {
        Button(isRail ? "Expand Sidebar" : "Collapse Sidebar", systemImage: "sidebar.left", action: action)
            .iconButtonStyle()
            .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
            .help(isRail ? "Expand the sidebar" : "Collapse the sidebar")
    }
}

/// Opens and closes the keyboard shortcut overlay, as Help ▸ Keyboard Shortcuts opens it (D3).
private struct ShortcutHelpButton: View {
    let pane: BrowserPane
    let isRail: Bool

    var body: some View {
        Button("Keyboard Shortcuts", systemImage: "questionmark", action: pane.toggleShortcutHelp)
            .iconButtonStyle()
            .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
            .help("Keyboard shortcuts")
            .accessibilityAddTraits(pane.window.isShortcutHelpVisible ? .isSelected : [])
    }
}

/// The shown workspace's symbol and name over its bookmarks and tabs (D6).
private struct WorkspaceHeader: View {
    let workspace: Workspace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: workspace.symbol)
                .symbolVariant(.fill)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A built-in workspace says what sets it apart, in the header's own colour, so it reads in light and dark.
                if let summary = workspace.summary {
                    Text(verbatim: summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace: \(workspace.name)")
        .accessibilityHint(workspace.summary ?? "")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct NewTabButton: View {
    let pane: BrowserPane

    var body: some View {
        Button("New Tab", systemImage: "plus", action: pane.newTab)
            .iconButtonStyle()
            .help(ShortcutCatalog.tooltip(String(localized: "Open a new tab"), for: .newTab))
    }
}

// MARK: Drag and drop (D4)

extension View {
    /// Lets the entry be dragged as a sidebar item of this workspace; nil leaves it put.
    @ViewBuilder
    fileprivate func sidebarDrag(_ item: SidebarDragItem?) -> some View {
        if let item {
            draggable(item)
        } else {
            self
        }
    }

    /// Takes sidebar items dropped here: `target` says where the dragged item, under the pointer at a point in a
    /// view of a size, would land, and the drop is offered only when the model allows it (`canDrop`), showing
    /// `indicator` for that point while it is. Plain text and other apps' data are never taken.
    fileprivate func sidebarDrop<Indicator: View>(
        _ model: BrowserModel,
        target: @escaping (SidebarDragItem, CGPoint, CGSize) -> SidebarDropTarget?,
        @ViewBuilder indicator: @escaping (CGPoint, CGSize) -> Indicator
    ) -> some View {
        modifier(SidebarDropZone(model: model, target: target, indicator: indicator))
    }
}

private struct SidebarDropZone<Indicator: View>: ViewModifier {
    let model: BrowserModel
    let target: (SidebarDragItem, CGPoint, CGSize) -> SidebarDropTarget?
    let indicator: (CGPoint, CGSize) -> Indicator
    /// The dragged item once its payload is read, while a drag is over the view.
    @State private var dragged: SidebarDragItem?
    @State private var location: CGPoint?
    @State private var size: CGSize = .zero
    /// Bumped as each drag enters and leaves, so a payload read for an earlier one is never taken for it.
    @State private var generation = 0
    @Environment(\.sidebarDragPresence) private var presence

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .onDrop(
                of: [.lodgeSidebarItem],
                delegate: Delegate(
                    model: model, target: target, size: size, presence: presence, dragged: $dragged,
                    location: $location, generation: $generation))
            .overlay {
                if let location, let dragged, allowed(dragged, at: location) != nil {
                    indicator(location, size)
                        .allowsHitTesting(false)
                }
            }
    }

    private func allowed(_ item: SidebarDragItem, at location: CGPoint) -> SidebarDropTarget? {
        target(item, location, size).flatMap { model.canDrop(item, on: $0) ? $0 : nil }
    }

    @MainActor
    private struct Delegate: DropDelegate {
        let model: BrowserModel
        let target: (SidebarDragItem, CGPoint, CGSize) -> SidebarDropTarget?
        let size: CGSize
        let presence: SidebarDragPresence?
        @Binding var dragged: SidebarDragItem?
        @Binding var location: CGPoint?
        @Binding var generation: Int

        func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.lodgeSidebarItem]) }

        /// Reads this drag's payload afresh; a read that ends after the drag left, or once another one entered, is
        /// dropped.
        func dropEntered(info: DropInfo) {
            presence?.touch()
            generation += 1
            let token = generation
            dragged = nil
            location = info.location
            guard let provider = info.itemProviders(for: [.lodgeSidebarItem]).first else { return }
            let (dragged, generation) = ($dragged, $generation)
            _ = provider.loadTransferable(type: SidebarDragItem.self) { result in
                let item = try? result.get()
                Task { @MainActor in
                    if generation.wrappedValue == token { dragged.wrappedValue = item }
                }
            }
        }

        /// Until the payload is read, nothing is promised: the pointer shows no move.
        func dropUpdated(info: DropInfo) -> DropProposal? {
            presence?.touch()
            location = info.location
            guard let dragged, allowed(dragged, at: info.location) != nil else {
                return DropProposal(operation: .forbidden)
            }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            presence?.leave()
            end()
        }

        func performDrop(info: DropInfo) -> Bool {
            presence?.end()
            defer { end() }
            guard let dragged, let place = allowed(dragged, at: info.location) else { return false }
            return model.drop(dragged, on: place)
        }

        private func end() {
            generation += 1
            location = nil
            dragged = nil
        }

        private func allowed(_ item: SidebarDragItem, at location: CGPoint) -> SidebarDropTarget? {
            target(item, location, size).flatMap { model.canDrop(item, on: $0) ? $0 : nil }
        }
    }
}

/// Where a drop will land: an accent line with a ring at its start, as the bookmark outline marks its own drops, so
/// every section of the sidebar shows the place the same way in light, dark and any workspace colour.
struct DropPlaceMark: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis

    static let thickness: CGFloat = 2
    private static let ring: CGFloat = 6

    var body: some View {
        let line = Capsule().fill(Color.accentColor)
        let ring = Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: Self.ring, height: Self.ring)
        switch axis {
        case .horizontal:
            HStack(spacing: 0) {
                ring
                line.frame(height: Self.thickness)
            }
            .frame(height: Self.ring)
        case .vertical:
            VStack(spacing: 0) {
                ring
                line.frame(width: Self.thickness)
            }
            .frame(width: Self.ring)
        }
    }
}

/// Whether a sidebar item is being dragged over the sidebar, so places that are hidden while empty (the pins) can show
/// a zone to drop on. Every drop zone, and the sidebar as a whole, reports the drag passing; it counts as gone a
/// moment after the last one it left, so moving from one zone to the next does not flicker.
@MainActor
@Observable
final class SidebarDragPresence {
    private(set) var isDragging = false
    @ObservationIgnored private var generation = 0

    func touch() {
        generation += 1
        if !isDragging { isDragging = true }
    }

    func leave() {
        generation += 1
        let token = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.generation == token else { return }
            self.isDragging = false
        }
    }

    func end() {
        generation += 1
        isDragging = false
    }
}

extension EnvironmentValues {
    @Entry var sidebarDragPresence: SidebarDragPresence?
}

/// Reports a sidebar item passing over the sidebar's background; it takes no drop itself.
private struct SidebarDragTracker: DropDelegate {
    let presence: SidebarDragPresence

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.lodgeSidebarItem]) }

    func dropEntered(info: DropInfo) { presence.touch() }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        presence.touch()
        return DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) { presence.leave() }

    func performDrop(info: DropInfo) -> Bool {
        presence.end()
        return false
    }
}

/// A drop into a place rather than between rows: the place's outline in the accent, as the bookmark outline marks a
/// drop onto a folder.
private struct DropIntoMark: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.accentColor.opacity(0.08))
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
    }
}

/// The place to pin while there are none, shown over the address only while a sidebar item is dragged: a ghost tile
/// that takes the item as the first pin.
private struct EmptyPinsDropZone: View {
    let model: BrowserModel

    var body: some View {
        let radius = ItemButton.Metrics.pin.cornerRadius
        Label("Drop here to pin", systemImage: "pin")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
            .sidebarDrop(model) { _, _, _ in .pins(index: 0) } indicator: { _, _ in DropIntoMark(cornerRadius: radius) }
            .accessibilityHidden(true)
    }
}
