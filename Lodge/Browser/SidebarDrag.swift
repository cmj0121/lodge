import AppKit
import CoreTransferable
import Foundation
import LodgeKit
import OSLog
import UniformTypeIdentifiers

extension UTType {
    /// A pin, bookmark, folder or loose tab dragged in the sidebar; only this app writes it, so no plain text or
    /// other app's data lands as a move.
    static let lodgeSidebarItem = UTType(exportedAs: "dev.lodge.sidebar-item")
}

/// What a sidebar drag carries: the kind of row, its id, and the workspace whose sidebar started it. A drop moves it
/// only within that workspace (`BrowserModel.canDrop(_:on:)`), and only when `nonce` is the drag this process has
/// going (`SidebarDragSession`), so a payload another app writes is never taken as a move.
struct SidebarDragItem: Codable, Hashable, Transferable {
    enum Kind: String, Codable { case pin, bookmark, folder, tab }
    let kind: Kind
    /// The link id, folder id, or `TabID`.
    let id: UUID
    let workspace: UUID
    /// The drag that carries it; nil for a move made from a menu or an accessibility action, which needs none.
    var nonce: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lodgeSidebarItem)
    }
}

/// Where a sidebar drop lands.
enum SidebarDropTarget: Equatable {
    /// Before the pin at `index` among the pins (Default's when shared).
    case pins(index: Int)
    /// Into `folder` (the root folder's id for the root) at `index` among its children; nil appends.
    case bookmarks(folder: UUID, index: Int?)
    /// Just before that loose tab; nil after the last loose tab.
    case loose(before: TabID?)
}

extension SidebarDragItem {
    /// The pasteboard type AppKit sources and destinations (the bookmark outline) read and write.
    static let pasteboardType = NSPasteboard.PasteboardType(UTType.lodgeSidebarItem.identifier)

    /// The item as `CodableRepresentation` writes it, JSON, for an AppKit pasteboard.
    var pasteboardData: Data? { try? JSONEncoder().encode(self) }

    /// The item an AppKit drag carries, read at drop time; nil when it carries none, when `source` is nil (the drag
    /// came from another process), or when it is not this process's live drag.
    @MainActor
    init?(pasteboard: NSPasteboard, source: Any?) {
        guard source != nil, let data = pasteboard.data(forType: Self.pasteboardType),
            let item = try? JSONDecoder().decode(Self.self, from: data), item.isLiveDrag
        else { return nil }
        self = item
    }

    /// The live drag while a drag of this process's (`source` not nil) carrying a sidebar item is over an AppKit
    /// view; read without touching the pasteboard's data, which is read only at drop time.
    @MainActor
    static func hovering(pasteboard: NSPasteboard, source: Any?) -> SidebarDragItem? {
        guard source != nil, pasteboard.availableType(from: [pasteboardType]) != nil else { return nil }
        return SidebarDragSession.current
    }

    /// Whether the item belongs to the drag this process has going.
    @MainActor
    var isLiveDrag: Bool { nonce.map(SidebarDragSession.isLive) == true }

    /// A provider for a SwiftUI drag of the item, which becomes the live drag as it starts. Its data is visible to
    /// every process, as the drag pasteboard is; the nonce rather than the pasteboard keeps other apps out.
    @MainActor
    func dragProvider() -> NSItemProvider {
        let data = SidebarDragSession.begin(self).pasteboardData
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.lodgeSidebarItem.identifier, visibility: .all) {
            completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// The one sidebar drag this process has going: the item, stamped with a fresh nonce as the drag starts. Drop zones
/// read it while the drag hovers, so nothing is loaded off the pasteboard until the drop; at the drop the payload's
/// nonce must be this one, or nothing moves. It ends when a drop lands, when another drag starts, at the next click in
/// Lodge, or when Lodge resigns active. A drag dropped outside Lodge or cancelled leaves the live item behind until one
/// of those, since SwiftUI's `.onDrag` gives no end callback and `DropInfo` no source. In that window a foreign drag
/// carrying this type gets the move mark over a SwiftUI drop zone and `performDrop` reports success to its source,
/// but `land` refuses its payload, so nothing moves; that is accepted. Another app can read the nonce off the drag
/// pasteboard, so it could replay it only in that window too, and only into a SwiftUI drop zone: the bookmark outline
/// also refuses a drag with no source in this process.
@MainActor
enum SidebarDragSession {
    private(set) static var current: SidebarDragItem?
    private static var clickMonitor: Any?
    private static var resignObserver: (any NSObjectProtocol)?
    private static let logger = Logger(subsystem: "dev.lodge", category: "drag")

    /// Makes `item`, stamped with a fresh nonce, the live drag, and returns it as the drag carries it.
    @discardableResult
    static func begin(_ item: SidebarDragItem) -> SidebarDragItem {
        var stamped = item
        stamped.nonce = UUID()
        current = stamped
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                end()
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { end() }
            }
        }
        logger.debug("Drag started: \(item.kind.rawValue, privacy: .public) \(item.id, privacy: .public)")
        return stamped
    }

    static func isLive(_ nonce: UUID) -> Bool { current?.nonce == nonce }

    static func end() { current = nil }

    static func log(_ message: String) { logger.debug("\(message, privacy: .public)") }
}

extension SidebarDragSession {
    /// The last step of a SwiftUI sidebar drop, once its payload is loaded: moves `live`, the drag that was live as it
    /// dropped, only when `payload` is that same drag, nonce and all.
    @discardableResult
    static func land(
        _ payload: SidebarDragItem?, live: SidebarDragItem, on place: SidebarDropTarget, in model: BrowserModel
    ) -> Bool {
        guard let payload, payload.nonce != nil, payload == live else {
            log("Drop \(live.kind.rawValue) \(live.id) on \(place): nonce mismatch, nothing moved")
            return false
        }
        let moved = model.drop(live, on: place)
        log("Drop \(live.kind.rawValue) \(live.id) on \(place): nonce ok, moved \(moved)")
        return moved
    }
}
