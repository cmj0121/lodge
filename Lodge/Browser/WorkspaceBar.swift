import AppKit
import LodgeKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's foot: one icon per workspace in bar order, New Workspace and Settings. A click switches, the
/// context menu renames or changes the icon, and a drag reorders, Default staying first. Past a few workspaces the
/// icons scroll: sideways in the sidebar, up and down in the rail.
struct WorkspaceBar: View {
    let coordinator: WorkspaceCoordinator
    let axis: Axis

    /// How many rail icons show before the rest scroll.
    private static let railVisible = 4
    private static let railSpacing: CGFloat = 6

    var body: some View {
        let isRail = axis == .vertical
        let layout = isRail ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            icons(isRail: isRail)
            Button("New Workspace", systemImage: "plus") { coordinator.active.showWorkspaceEditor(.create) }
                .iconButtonStyle()
                .help("New workspace")
            SettingsButton()
        }
        .font(isRail ? .system(size: SidebarMode.railSymbolSize) : nil)
        .padding(.horizontal, isRail ? 0 : 4)
    }

    private func icons(isRail: Bool) -> some View {
        let workspaces = coordinator.workspaces.workspaces
        let activeID = coordinator.activeWorkspace.id
        let shown = min(workspaces.count, Self.railVisible)
        return ScrollViewReader { proxy in
            ScrollView(isRail ? .vertical : .horizontal) {
                let layout =
                    isRail
                    ? AnyLayout(VStackLayout(spacing: Self.railSpacing)) : AnyLayout(HStackLayout(spacing: 2))
                layout {
                    ForEach(workspaces) { workspace in
                        WorkspaceIcon(
                            coordinator: coordinator, workspace: workspace, isActive: workspace.id == activeID,
                            isRail: isRail)
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(
                height: isRail
                    ? CGFloat(shown) * WorkspaceIcon.railHeight + CGFloat(shown - 1) * Self.railSpacing
                    : WorkspaceIcon.barHeight)
            .onAppear { proxy.scrollTo(activeID) }
            .onChange(of: activeID) { proxy.scrollTo(activeID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspaces")
    }
}

/// One workspace as its symbol, its name as the tooltip, filled and on a tile while it is the one shown.
private struct WorkspaceIcon: View {
    static let railHeight: CGFloat = 36
    static let barHeight: CGFloat = 24

    let coordinator: WorkspaceCoordinator
    let workspace: Workspace
    let isActive: Bool
    let isRail: Bool
    @State private var isHovered = false

    private var isDefault: Bool { workspace.kind == .default }

    private var index: Int? { coordinator.workspaces.workspaces.firstIndex { $0.id == workspace.id } }

    private var tooltip: String {
        guard let slot = coordinator.workspaces.slot(of: workspace.id), let id = ShortcutID.workspace(slot: slot)
        else { return workspace.name }
        return ShortcutCatalog.tooltip(workspace.name, for: id)
    }

    var body: some View {
        Button {
            coordinator.switchTo(workspace.id)
        } label: {
            Image(systemName: workspace.symbol)
                .symbolVariant(isActive ? .fill : .none)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: isRail ? 46 : 28, height: isRail ? Self.railHeight : Self.barHeight)
                .background(rowBackground(isSelected: isActive, isHovered: isHovered, cornerRadius: isRail ? 10 : 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(workspace.id)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel("Workspace: \(workspace.name)")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityActions {
            if !isDefault {
                Button(isRail ? "Move Up" : "Move Left") { move(by: -1) }
                Button(isRail ? "Move Down" : "Move Right") { move(by: 1) }
                Button("Rename…") { edit(.rename(workspace.id)) }
            }
            Button("Change Icon…") { edit(.changeIcon(workspace.id)) }
            if !isDefault {
                Button("Delete…") { WorkspacePrompts.delete(workspace, coordinator: coordinator) }
            }
        }
        .contextMenu {
            if !isDefault {
                Button("Rename…") { edit(.rename(workspace.id)) }
            }
            Button("Change Icon…") { edit(.changeIcon(workspace.id)) }
            if !isDefault {
                Divider()
                Button("Delete…") { WorkspacePrompts.delete(workspace, coordinator: coordinator) }
            }
        }
        .modifier(WorkspaceDrag(workspace: isDefault ? nil : workspace.id))
        .dropDestination(for: WorkspaceDragItem.self) { payload, _ in
            guard let dragged = payload.first?.ownWorkspace,
                let move = coordinator.workspaces.reorder(dragging: dragged, onto: workspace.id)
            else { return false }
            return withAnimation(.snappy(duration: 0.2)) { coordinator.move(from: move.from, to: move.to) }
        } isTargeted: {
            isHovered = $0
        }
    }

    private func edit(_ editor: WorkspaceEditor) {
        coordinator.active.showWorkspaceEditor(editor)
    }

    private func move(by offset: Int) {
        if let index { coordinator.move(from: index, to: index + offset) }
    }
}

/// Lets a custom workspace be dragged, carrying its id; Default stays put.
private struct WorkspaceDrag: ViewModifier {
    let workspace: UUID?

    func body(content: Content) -> some View {
        if let workspace {
            content.draggable(WorkspaceDragItem(workspace: workspace))
        } else {
            content
        }
    }
}

extension UTType {
    /// A workspace being dragged along the bar; only this app writes it, so no other app's text lands as a move.
    fileprivate static let lodgeWorkspace = UTType(exportedAs: "dev.lodge.workspace-drag", conformingTo: .data)
}

/// What a workspace drag carries: the workspace and this launch's token. The bar reads no other type, and a payload
/// of that type from anywhere but this process (its token unknown outside it) moves nothing.
private struct WorkspaceDragItem: Codable, Transferable {
    private static let launchToken = UUID()

    let workspace: UUID
    private let token: UUID

    init(workspace: UUID) {
        self.workspace = workspace
        token = Self.launchToken
    }

    /// The dragged workspace when this launch started the drag; nil otherwise.
    var ownWorkspace: UUID? { token == Self.launchToken ? workspace : nil }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lodgeWorkspace)
    }
}

private struct SettingsButton: View {
    var body: some View {
        SettingsLink { Label("Settings", systemImage: "gearshape") }
            .iconButtonStyle()
            .help("Settings (⌘,)")
    }
}

/// The question Delete… asks before a workspace and everything in it goes.
@MainActor
enum WorkspacePrompts {
    static func delete(_ workspace: Workspace, coordinator: WorkspaceCoordinator) {
        guard workspace.kind != .default else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(workspace.name)”?"
        alert.informativeText =
            "Its tabs close, and its bookmarks, history, sign-ins and site data are deleted. This cannot be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let handle = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            Task { await coordinator.delete(workspace.id) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
