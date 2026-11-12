import AppKit
import LodgeKit
import SwiftUI

/// The bookmark tree in the sidebar: an outline view whose rows are the sidebar's own SwiftUI rows, so
/// bookmarks and folders drag natively between rows and onto folders. It is as tall as its rows; the
/// sidebar's scroll view scrolls it.
struct BookmarkOutline: NSViewRepresentable {
    let model: BrowserModel
    let nodes: [SidebarNode]

    static let rowHeight = SidebarRowLabel.Metrics.height
    static let rowSpacing: CGFloat = 2
    /// How far each folder level sets its rows in.
    static let indent: CGFloat = 16

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> OutlineContainer {
        let container = OutlineContainer(outline: context.coordinator.outline)
        context.coordinator.update(nodes)
        return container
    }

    func updateNSView(_ container: OutlineContainer, context: Context) {
        context.coordinator.model = model
        context.coordinator.update(nodes)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OutlineContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: nsView.contentHeight)
    }

    /// Feeds the outline from the sidebar's bookmark nodes and turns its clicks, drags, expansion and
    /// context menu into model actions.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: BrowserModel
        let outline = TreeOutlineView()
        let rows = BookmarkRows()

        private var nodes: [SidebarNode] = []
        /// One stable object per node, as the outline tells items apart by identity.
        private var items: [SidebarItem.ID: Item] = [:]
        /// Each folder's child ids in order; nil is the root.
        private var childIDs: [SidebarItem.ID?: [SidebarItem.ID]] = [:]
        /// Where each node sits: its folder (nil for the root) and its index there.
        private var places: [SidebarItem.ID: (parent: SidebarItem.ID?, index: Int)] = [:]
        /// Set while the outline is brought in line with the model, so its expand and collapse
        /// notifications are not written back.
        private var isSyncing = false

        private static let dragType = NSPasteboard.PasteboardType("dev.lodge.bookmark-node")
        private static let cellID = NSUserInterfaceItemIdentifier("BookmarkCell")
        private static let rowID = NSUserInterfaceItemIdentifier("BookmarkRow")

        init(model: BrowserModel) {
            self.model = model
            super.init()
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Bookmark"))
            outline.addTableColumn(column)
            outline.outlineTableColumn = column
            outline.headerView = nil
            outline.style = .plain
            outline.backgroundColor = .clear
            outline.gridStyleMask = []
            outline.focusRingType = .none
            outline.selectionHighlightStyle = .none
            // The rows draw their own indent; the outline's lets the pointer's x pick a drop's depth.
            outline.indentationPerLevel = BookmarkOutline.indent
            outline.autoresizesOutlineColumn = false
            outline.rowHeight = BookmarkOutline.rowHeight
            outline.intercellSpacing = NSSize(width: 0, height: BookmarkOutline.rowSpacing)
            // Clicks leave the keyboard with the page, as the sidebar's other rows do.
            outline.refusesFirstResponder = true
            outline.registerForDraggedTypes([Self.dragType])
            outline.setDraggingSourceOperationMask(.move, forLocal: true)
            outline.draggingDestinationFeedbackStyle = .regular
            outline.dataSource = self
            outline.delegate = self
            outline.target = self
            outline.action = #selector(clicked(_:))
            let menu = NSMenu()
            menu.delegate = self
            outline.menu = menu
            outline.onVisibleRowsChange = { [weak self] in self?.refreshHover() }
        }

        /// Takes the sidebar's latest nodes. Row content updates in place; the outline reloads only when
        /// the tree's shape (which node sits where) changes, and its expansion follows each folder's state.
        func update(_ nodes: [SidebarNode]) {
            guard nodes != self.nodes else { return }
            self.nodes = nodes
            var flat: [SidebarItem.ID: SidebarNode] = [:]
            var depths: [SidebarItem.ID: Int] = [:]
            var children: [SidebarItem.ID?: [SidebarItem.ID]] = [:]
            var places: [SidebarItem.ID: (parent: SidebarItem.ID?, index: Int)] = [:]
            func walk(_ list: [SidebarNode], in parent: SidebarItem.ID?, depth: Int) {
                children[parent] = list.map(\.id)
                for (index, node) in list.enumerated() {
                    flat[node.id] = node
                    depths[node.id] = depth
                    places[node.id] = (parent, index)
                    if case .folder(_, _, _, let nested) = node { walk(nested, in: node.id, depth: depth + 1) }
                }
            }
            walk(nodes, in: nil, depth: 0)
            rows.nodes = flat
            if children != childIDs {
                childIDs = children
                self.places = places
                rows.depths = depths
                items = flat.keys.reduce(into: [:]) { $0[$1] = items[$1] ?? Item($1) }
                outline.reloadData()
            }
            applyExpansion()
            outline.superview?.invalidateIntrinsicContentSize()
            outline.refreshPreparedContent()
        }

        /// Points the hover highlight at the row under the pointer now, as rows move under a still pointer
        /// when the outline reloads, expands or scrolls.
        private func refreshHover() {
            var hovered: SidebarItem.ID?
            if NSApp.isActive, let window = outline.window {
                let point = outline.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let row = outline.visibleRect.contains(point) ? outline.row(at: point) : -1
                hovered = row < 0 ? nil : id(outline.item(atRow: row))
            }
            if rows.hovered != hovered { rows.hovered = hovered }
        }

        /// Expands and collapses folders to match the model, top down through the open ones.
        private func applyExpansion() {
            isSyncing = true
            defer { isSyncing = false }
            func apply(_ parent: SidebarItem.ID?) {
                for id in childIDs[parent] ?? [] {
                    guard case .folder(_, _, let isExpanded, _)? = rows.nodes[id], let item = items[id] else { continue }
                    if isExpanded != outline.isItemExpanded(item) {
                        if isExpanded { outline.expandItem(item) } else { outline.collapseItem(item) }
                    }
                    if isExpanded { apply(id) }
                }
            }
            apply(nil)
        }

        private func id(_ item: Any?) -> SidebarItem.ID? { (item as? Item)?.id }

        /// The library id of the folder `id` names, the root for nil.
        private func folderID(_ id: SidebarItem.ID?) -> UUID { id?.bookmarkID ?? model.library.bookmarks.id }

        private func node(atRow row: Int) -> SidebarNode? {
            row < 0 ? nil : id(outline.item(atRow: row)).flatMap { rows.nodes[$0] }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            childIDs[id(item)]?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            items[childIDs[id(item)]![index]]!
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if case .folder? = id(item) { true } else { false }
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let id = id(item) else { return nil }
            let row = BookmarkTreeRow(model: model, rows: rows, id: id)
            if let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? RowHost {
                cell.rootView = row
                return cell
            }
            let cell = RowHost(rootView: row)
            cell.identifier = Self.cellID
            cell.sizingOptions = []
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            guard let id = id(item) else { return nil }
            let rowView = outlineView.makeView(withIdentifier: Self.rowID, owner: nil) as? RowView ?? RowView()
            rowView.identifier = Self.rowID
            rowView.onHover = { [rows] isHovered in
                if isHovered {
                    rows.hovered = id
                } else if rows.hovered == id {
                    rows.hovered = nil
                }
            }
            rowView.content = { [weak self] in self?.rowContent(id) }
            return rowView
        }

        /// What the row of `id` tells VoiceOver and its tooltip, read when asked so it follows renames and tabs.
        private func rowContent(_ id: SidebarItem.ID) -> RowView.Content? {
            switch rows.nodes[id] {
            case .folder(let folder, let title, let isExpanded, _)?:
                return RowView.Content(
                    label: title, value: isExpanded ? "Folder, expanded" : "Folder, collapsed", toolTip: nil,
                    isSelected: false, actions: [(isExpanded ? "Collapse" : "Expand", { [model] in model.setFolderExpanded(folder, !isExpanded) })])
            case .item(let item)?:
                var actions: [(String, () -> Void)] = [("Open", { [model] in model.activate(item.target) })]
                if let tab = item.tab { actions.append(("Close Tab", { [model] in model.close(tab.id) })) }
                return RowView.Content(
                    label: item.title, value: nil, toolTip: item.address,
                    isSelected: item.isSelected(model.tabs.selectedID), actions: actions)
            case nil:
                return nil
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, to: true) }

        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, to: false) }

        private func expansionChanged(_ notification: Notification, to isExpanded: Bool) {
            outline.superview?.invalidateIntrinsicContentSize()
            outline.refreshPreparedContent()
            guard !isSyncing, case .folder(let folder)? = id(notification.userInfo?["NSObject"]) else { return }
            model.setFolderExpanded(folder, isExpanded)
        }

        /// A click opens or closes a folder, closes the tab on its close button, or activates the bookmark.
        @objc private func clicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            switch node(atRow: row) {
            case .folder(let id, _, let isExpanded, _)?:
                // A double click's second click would close the folder its first one opened.
                guard (NSApp.currentEvent?.clickCount ?? 1) <= 1 else { return }
                model.setFolderExpanded(id, !isExpanded)
            case .item(let item)?:
                let showsClose = rows.hovered == item.id || item.isSelected(model.tabs.selectedID)
                if let tab = item.tab, showsClose, isOnCloseButton(row) {
                    model.close(tab.id)
                } else {
                    model.activate(item.target)
                }
            case nil:
                break
            }
        }

        /// Whether the click that ended just now fell on the row's trailing close button, give or take a
        /// few points of slack.
        private func isOnCloseButton(_ row: Int) -> Bool {
            guard let event = NSApp.currentEvent else { return false }
            let point = outline.convert(event.locationInWindow, from: nil)
            let metrics = SidebarRowLabel.Metrics.self
            return point.x >= outline.rect(ofRow: row).maxX - metrics.padding - metrics.iconSize - 4
        }

        // MARK: Drag

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let bookmark = id(item)?.bookmarkID else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(bookmark.uuidString, forType: Self.dragType)
            return writer
        }

        /// A drop onto a bookmark lands just after it; a folder moving into itself or below itself is refused.
        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let dragged = draggedID(info, in: outlineView) else { return [] }
            var parent = id(item)
            if index == NSOutlineViewDropOnItemIndex, case .link? = parent, let place = places[parent!] {
                parent = place.parent
                outlineView.setDropItem(parent.flatMap { items[$0] }, dropChildIndex: place.index + 1)
            }
            return model.library.canMoveBookmark(dragged, into: folderID(parent)) ? .move : []
        }

        func outlineView(
            _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int
        ) -> Bool {
            guard let dragged = draggedID(info, in: outlineView) else { return false }
            return model.moveBookmark(
                dragged, into: folderID(id(item)), at: index == NSOutlineViewDropOnItemIndex ? nil : index)
        }

        /// The bookmark being dragged, only when the drag started in `outlineView`: another app can put the same
        /// pasteboard type on a drag of its own.
        private func draggedID(_ info: NSDraggingInfo, in outlineView: NSOutlineView) -> UUID? {
            guard (info.draggingSource as AnyObject?) === outlineView else { return nil }
            return info.draggingPasteboard.string(forType: Self.dragType).flatMap(UUID.init(uuidString:))
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let row = outline.clickedRow
            switch node(atRow: row) {
            case .folder(let id, let title, _, _)?:
                menu.addItem(ClosureMenuItem("New Folder…") { [model] in BookmarkPrompts.newFolder(in: id, model: model) })
                menu.addItem(ClosureMenuItem("Rename…") { [model] in BookmarkPrompts.rename(id, title: title, model: model) })
                menu.addItem(.separator())
                menu.addItem(
                    ClosureMenuItem("Delete Folder…") { [model] in
                        BookmarkPrompts.deleteFolder(id, title: title, model: model)
                    })
            case .item(.link(let link, _, let tab))?:
                let parent = folderID(places[.link(link.id)]?.parent)
                menu.addItem(ClosureMenuItem("New Folder…") { [model] in BookmarkPrompts.newFolder(in: parent, model: model) })
                menu.addItem(
                    ClosureMenuItem("Rename…") { [model] in BookmarkPrompts.rename(link.id, title: link.title, model: model) })
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Remove from Bookmarks") { [model] in model.removeLink(link.id) })
                if let tab {
                    menu.addItem(.separator())
                    menu.addItem(ClosureMenuItem("Close Tab") { [model] in model.close(tab.id) })
                }
            case .item(.tab)?, nil:
                menu.addItem(ClosureMenuItem("New Folder…") { [model] in BookmarkPrompts.newFolder(in: nil, model: model) })
            }
        }
    }

    /// An outline item: the node's id, boxed once so the outline sees the same object across updates.
    final class Item: NSObject {
        let id: SidebarItem.ID

        init(_ id: SidebarItem.ID) { self.id = id }
    }
}

/// What the tree's SwiftUI rows read: every node by id with its depth, and the row under the pointer.
@MainActor
@Observable
final class BookmarkRows {
    var nodes: [SidebarItem.ID: SidebarNode] = [:]
    var depths: [SidebarItem.ID: Int] = [:]
    var hovered: SidebarItem.ID?
}

/// Holds the outline at its full width and reports its rows' height, so it never scrolls on its own.
final class OutlineContainer: NSView {
    let outline: NSOutlineView

    init(outline: NSOutlineView) {
        self.outline = outline
        super.init(frame: .zero)
        addSubview(outline)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    var contentHeight: CGFloat {
        CGFloat(outline.numberOfRows) * (BookmarkOutline.rowHeight + BookmarkOutline.rowSpacing)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: contentHeight) }

    override func layout() {
        super.layout()
        outline.frame = bounds
        outline.tableColumns.first?.width = bounds.width
    }
}

/// An outline whose rows span its full width: the rows draw their own indent and disclosure chevron.
/// It sits in the sidebar's scroll view rather than one of its own, so it builds row views only for
/// the part that scroll view shows, and builds more as it scrolls.
final class TreeOutlineView: NSOutlineView {
    /// Called whenever the rows shown may have changed: a scroll, a resize, a move, an expand or a reload.
    var onVisibleRowsChange: (() -> Void)?
    private var scrollObserver: (any NSObjectProtocol)?
    /// Rows past each edge of the shown part that keep their views, so short scrolls find them ready.
    private static let overdraw: CGFloat = 400

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// Nothing shows before the outline is in a window, so no row views are built for it then.
    override var visibleRect: NSRect { window == nil ? .zero : super.visibleRect }

    override var preparedContentRect: NSRect {
        get { super.preparedContentRect }
        set { super.preparedContentRect = newValue.intersection(visibleRect.insetBy(dx: 0, dy: -Self.overdraw)) }
    }

    /// Builds row views for the part shown plus the overdraw, and drops the rest.
    func refreshPreparedContent() {
        preparedContentRect = visibleRect.insetBy(dx: 0, dy: -Self.overdraw)
        onVisibleRowsChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshPreparedContent()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        refreshPreparedContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPreparedContent() }
            }
        }
        refreshPreparedContent()
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rect = rect(ofRow: row)
        return NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)
    }
}

/// A row's SwiftUI content. It only draws: clicks, drags and the menu go to the outline beneath it.
final class RowHost: NSHostingView<BookmarkTreeRow> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row with no system selection. It reports the pointer entering and leaving for the hover highlight,
/// and, as its SwiftUI content takes no pointer events, gives the tooltip and VoiceOver the row's title,
/// state and actions itself.
final class RowView: NSTableRowView, NSViewToolTipOwner {
    struct Content {
        let label: String
        let value: String?
        let toolTip: String?
        /// Whether the row's bookmark has the selected tab.
        let isSelected: Bool
        let actions: [(name: String, run: () -> Void)]
    }

    var onHover: ((Bool) -> Void)?
    var content: (() -> Content?)?
    private var tracking: NSTrackingArea?

    override func drawSelection(in dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?)
        -> String
    {
        content?()?.toolTip ?? ""
    }

    override func accessibilityLabel() -> String? { content?()?.label }

    override func accessibilityValue() -> Any? { content?()?.value }

    override func isAccessibilitySelected() -> Bool { content?()?.isSelected ?? false }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        content?()?.actions.map { action in
            NSAccessibilityCustomAction(name: action.name) {
                action.run()
                return true
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("ClosureMenuItem is never decoded") }

    @objc private func run() { handler() }
}

/// The sheets bookmark editing asks with: naming a new folder, renaming, and confirming a folder delete.
@MainActor
enum BookmarkPrompts {
    /// Asks for a name, then adds the folder to `parent` (nil: the root).
    static func newFolder(in parent: UUID?, model: BrowserModel) {
        let (alert, field) = nameAlert(message: "New Folder", name: "New Folder", confirm: "Create")
        present(alert) { response in
            if response == .alertFirstButtonReturn { model.newFolder(in: parent, title: field.stringValue) }
        }
    }

    static func rename(_ id: UUID, title: String, model: BrowserModel) {
        let (alert, field) = nameAlert(message: "Rename “\(title)”", name: title, confirm: "Rename")
        present(alert) { response in
            if response == .alertFirstButtonReturn { model.rename(id, to: field.stringValue) }
        }
    }

    /// Asks before deleting the folder and every bookmark in it.
    static func deleteFolder(_ id: UUID, title: String, model: BrowserModel) {
        let count = model.library.folder(id)?.bookmarkCount ?? 0
        let alert = NSAlert()
        alert.messageText =
            switch count {
            case 0: "Delete “\(title)”?"
            case 1: "Delete “\(title)” and the bookmark in it?"
            default: "Delete “\(title)” and the \(count) bookmarks in it?"
            }
        alert.informativeText = "Tabs open on these bookmarks stay open."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn { model.removeLink(id) }
        }
    }

    private static func nameAlert(message: String, name: String, confirm: String) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Name")
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return (alert, field)
    }

    private static func present(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

extension SidebarItem.ID {
    /// The library id of a bookmark or folder; nil for a loose tab.
    fileprivate var bookmarkID: UUID? {
        switch self {
        case .link(let id), .folder(let id): id
        case .tab: nil
        }
    }
}

extension BookmarkFolder {
    /// How many bookmarks the folder holds, in every sub-folder too.
    fileprivate var bookmarkCount: Int {
        children.reduce(0) { count, node in
            switch node {
            case .link: count + 1
            case .folder(let folder): count + folder.bookmarkCount
            }
        }
    }
}
