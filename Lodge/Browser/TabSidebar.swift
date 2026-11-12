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

    var body: some View {
        switch mode {
        case .expanded: ExpandedSidebar(model: model, toggle: toggle)
        case .rail: RailSidebar(model: model, toggle: toggle)
        }
    }
}

/// Navigation beside the window buttons, the address, pins, the workspace's bookmarks and loose
/// tabs, and the workspace bar.
private struct ExpandedSidebar: View {
    let model: BrowserModel
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
                        Text(defaultWorkspaceName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        NewTabButton(model: model)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    rows(items.bookmarks)
                    if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    rows(items.loose)
                }
            }
            .scrollIndicators(.never)
            Divider()
            WorkspaceBar(axis: .horizontal)
                .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func rows(_ items: [SidebarItem]) -> some View {
        let selected = model.tabs.selectedID
        return ForEach(items) {
            SidebarRow(model: model, item: $0, isLive: $0.isLive(selected: selected), favicon: model.favicon(for: $0))
        }
    }
}

/// Icons only: expand, pins, the bookmarks menu and the workspace bar.
private struct RailSidebar: View {
    let model: BrowserModel
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
                            model: model, item: $0, isLive: $0.isLive(selected: selected),
                            favicon: model.favicon(for: $0), shape: .rail)
                    }
                    if !items.bookmarks.isEmpty || !items.loose.isEmpty {
                        BookmarksMenu(model: model, items: items)
                    }
                }
            }
            .scrollIndicators(.never)
            WorkspaceBar(axis: .vertical)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

/// The rail's stand-in for the bookmark and loose tab rows: one button whose menu lists them,
/// filled while one of them is the live session.
private struct BookmarksMenu: View {
    let model: BrowserModel
    let items: SidebarSections
    @State private var isHovered = false

    var body: some View {
        let selected = model.tabs.selectedID
        let isLive = (items.bookmarks + items.loose).contains { $0.isLive(selected: selected) }
        let shape = ItemButton.Metrics.rail
        Menu {
            entries(items.bookmarks, selected: selected)
            if !items.bookmarks.isEmpty && !items.loose.isEmpty {
                Divider()
            }
            entries(items.loose, selected: selected)
        } label: {
            Image(systemName: isLive ? "book.fill" : "book")
                .font(.system(size: SidebarMode.railSymbolSize))
                .foregroundStyle(isLive ? .primary : .secondary)
                .frame(width: shape.width, height: shape.height)
                .background(rowBackground(isLive: isLive, isHovered: isHovered, cornerRadius: shape.cornerRadius))
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("Bookmarks")
        .accessibilityLabel("Bookmarks")
        .accessibilityValue(isLive ? "Open" : "")
    }

    private func entries(_ items: [SidebarItem], selected: TabID?) -> some View {
        ForEach(items) { item in
            Toggle(
                isOn: Binding(get: { item.isLive(selected: selected) }, set: { _ in model.activate(item.target) })
            ) {
                Label {
                    Text(item.title)
                } icon: {
                    MenuIcon(content: IconContent(item: item, favicon: model.favicon(for: item)))
                }
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

/// Pin, Bookmark, Remove and Close, as fit the item.
private struct ItemMenu: View {
    let model: BrowserModel
    let item: SidebarItem

    var body: some View {
        switch item {
        case .link(let link, let shelf, _):
            Button(shelf == .pins ? "Remove from Pins" : "Remove from Bookmarks") { model.removeLink(link.id) }
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

/// What an item's icon shows, decided once for the sidebar and the rail's bookmarks menu: the live
/// tab's status, else the first letter of a link that is not open.
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

/// The item's icon: the live tab's status, else a dimmed letter tile for a link that is not open.
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
private struct LetterIcon: View {
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

/// The highlight under a row or tile: filled for the live session, faint on hover.
func rowBackground(isLive: Bool, isHovered: Bool, cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.primary.opacity(isLive ? 0.12 : isHovered ? 0.05 : 0))
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
                    model: model, item: $0, isLive: $0.isLive(selected: selected), favicon: model.favicon(for: $0),
                    shape: .pin)
            }
        }
    }
}

/// An item as its icon alone, the title as a tooltip: a pin tile, or an entry in the rail.
private struct ItemButton: View {
    struct Metrics {
        let iconSize: CGFloat
        /// Nil fills the width on offer.
        let width: CGFloat?
        let height: CGFloat
        let cornerRadius: CGFloat
        /// Whether the icon sits on a quiet tile of its own while not live.
        let isTile: Bool

        static let pin = Metrics(iconSize: 18, width: nil, height: 40, cornerRadius: 9, isTile: true)
        static let rail = Metrics(iconSize: 24, width: 46, height: 40, cornerRadius: 10, isTile: false)
    }

    let model: BrowserModel
    let item: SidebarItem
    let isLive: Bool
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
                    .quaternary.opacity(shape.isTile && !isLive ? 0.5 : 0), in: .rect(cornerRadius: shape.cornerRadius)
                )
                .background(rowBackground(isLive: isLive, isHovered: isHovered, cornerRadius: shape.cornerRadius))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .sidebarItem(item, model: model, isHovered: $isHovered)
    }
}

/// A bookmark or loose tab with its title; the live one carries a close button.
private struct SidebarRow: View {
    let model: BrowserModel
    let item: SidebarItem
    let isLive: Bool
    let favicon: NSImage?
    @State private var isHovered = false

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
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovered || isLive ? 1 : 0)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close \(item.title)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(rowBackground(isLive: isLive, isHovered: isHovered, cornerRadius: 7))
        .contentShape(.rect)
        .onTapGesture { model.activate(item.target) }
        .help(item.address)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isLive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.activate(item.target) }
        .accessibilityActions {
            if let tab = item.tab {
                Button("Close Tab") { model.close(tab.id) }
            }
        }
        .sidebarItem(item, model: model, isHovered: $isHovered)
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
            .help("\(verb) the sidebar (⌃⌘S)")
    }
}

private struct NewTabButton: View {
    let model: BrowserModel

    var body: some View {
        Button("New Tab", systemImage: "plus", action: model.newTab)
            .iconButtonStyle()
            .help("Open a new tab (⌘T)")
    }
}
