import CoreTransferable
import Foundation
import LodgeKit
import UniformTypeIdentifiers

extension UTType {
    /// A pin, bookmark, folder or loose tab dragged in the sidebar; only this app writes it, so no plain text or
    /// other app's data lands as a move.
    static let lodgeSidebarItem = UTType(exportedAs: "dev.lodge.sidebar-item")
}

/// What a sidebar drag carries: the kind of row, its id, and the workspace whose sidebar started it. A drop moves it
/// only within that workspace (`BrowserModel.canDrop(_:on:)`).
struct SidebarDragItem: Codable, Hashable, Transferable {
    enum Kind: String, Codable { case pin, bookmark, folder, tab }
    let kind: Kind
    /// The link id, folder id, or `TabID`.
    let id: UUID
    let workspace: UUID

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
