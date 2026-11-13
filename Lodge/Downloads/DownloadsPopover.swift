import AppKit
import LodgeKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's Downloads button (D2): the download icon, a ring while downloads run, and a dot while something
/// ended unseen (D5). It opens the Downloads popover, as ⌘J does.
struct DownloadsButton: View {
    @Bindable var model: BrowserModel
    let manager: DownloadManager
    let isRail: Bool

    var body: some View {
        let progress = manager.list.overallProgress
        Button {
            model.isDownloadsVisible.toggle()
        } label: {
            DownloadsButtonLabel(
                progress: progress, hasUnseen: manager.hasUnseenEnded,
                size: isRail ? SidebarMode.railSymbolSize : DownloadsButtonLabel.barSymbolSize)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(ShortcutCatalog.tooltip("Downloads", for: .toggleDownloads))
        .accessibilityLabel("Downloads")
        .accessibilityValue(DownloadsButtonLabel.accessibilityValue(progress, hasUnseen: manager.hasUnseenEnded))
        .popover(isPresented: $model.isDownloadsVisible, arrowEdge: .trailing) {
            DownloadsPopover(manager: manager)
        }
    }
}

/// The button's look for the whole list: the plain icon, or a ring (filling, or turning while the size is unknown)
/// around a small arrow, with the unseen dot on top.
struct DownloadsButtonLabel: View {
    /// The expanded sidebar's symbol size, matched to the workspace bar's other buttons.
    static let barSymbolSize: CGFloat = 15

    let progress: DownloadOverallProgress
    let hasUnseen: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch progress {
            case .none:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: size))
            case .determinate(let fraction):
                ring(to: fraction, turn: 0)
            case .indeterminate:
                if reduceMotion {
                    ring(to: 0.3, turn: 0)
                } else {
                    // One turn a second.
                    TimelineView(.animation) { context in
                        let seconds = context.date.timeIntervalSinceReferenceDate
                        ring(to: 0.3, turn: seconds.truncatingRemainder(dividingBy: 1))
                    }
                }
            }
        }
        // A symbol draws a little larger than its point size.
        .frame(width: size * 1.15, height: size * 1.15)
        .overlay(alignment: .topTrailing) {
            if hasUnseen {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .offset(x: size * 0.12, y: -size * 0.08)
            }
        }
        .animation(.snappy(duration: 0.2), value: hasUnseen)
    }

    /// The track, an arc over it from the top to `end` turned by `turn` of a circle, and the arrow inside.
    private func ring(to end: Double, turn: Double) -> some View {
        let line = max(1.5, size * 0.09)
        return ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: line)
            Circle()
                .trim(from: 0, to: end)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(turn * 360 - 90))
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.5, weight: .semibold))
        }
        .padding(line / 2 + size * 0.06)
    }

    static func accessibilityValue(_ progress: DownloadOverallProgress, hasUnseen: Bool) -> String {
        let running =
            switch progress {
            case .none: ""
            case .determinate(let fraction): fraction.formatted(.percent.precision(.fractionLength(0)))
            case .indeterminate: "In progress"
            }
        return [running, hasUnseen ? "New finished downloads" : ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The Downloads popover over the manager's list. Opening it marks every ended item seen and checks the finished
/// files, so a moved one reads "File moved or deleted".
struct DownloadsPopover: View {
    let manager: DownloadManager

    var body: some View {
        DownloadsList(
            list: manager.list, missing: manager.missing, onAction: manager.rowAction, clear: manager.clearEnded
        )
        .onAppear {
            manager.markSeen()
            manager.refreshMissing()
        }
        // Whatever ends while it is open is seen as it ends.
        .onChange(of: manager.hasUnseenEnded) { _, hasUnseen in
            if hasUnseen { manager.markSeen() }
        }
    }
}

extension DownloadManager {
    func rowAction(_ id: UUID, _ action: DownloadRowModel.Action) {
        switch action {
        case .cancel: cancel(id)
        case .retry: retry(id)
        case .open: open(id)
        case .showInFinder: showInFinder(id)
        case .remove: remove(id)
        }
    }
}

/// The popover's content: the rows newest first and Clear, or "No Downloads" (D5).
struct DownloadsList: View {
    static let width: CGFloat = 340

    let list: DownloadList
    let missing: Set<UUID>
    /// One handler for every row, told which row it is for.
    let onAction: (UUID, DownloadRowModel.Action) -> Void
    let clear: () -> Void
    /// Rows past this many scroll.
    var visibleRows = 7

    var body: some View {
        Group {
            if list.items.isEmpty {
                Text("No Downloads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: DownloadRow.spacing) {
                            ForEach(list.items) { item in
                                DownloadRow(
                                    id: item.id, name: item.fileName, fileURL: item.fileURL,
                                    row: DownloadRowModel(item, isMissing: missing.contains(item.id)), onAction: onAction
                                )
                                .equatable()
                            }
                        }
                        .padding(6)
                    }
                    // Shown scrollers do not draw in a layout render, and the sidebar hides its own.
                    .scrollIndicators(.never)
                    .frame(height: listHeight)
                    Divider()
                    HStack {
                        Spacer(minLength: 0)
                        Button("Clear", action: clear)
                            .disabled(!list.hasEnded)
                            .help("Remove every finished, failed, cancelled and interrupted download from the list")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: Self.width)
    }

    /// Fits the rows, up to `visibleRows` of them.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(list.items.count, visibleRows))
        return rows * DownloadRow.height + (rows - 1) * DownloadRow.spacing + 12
    }
}

extension DownloadRowModel.Action {
    var title: String {
        switch self {
        case .cancel: "Cancel"
        case .retry: "Retry"
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .remove: "Remove"
        }
    }

    var systemImage: String {
        switch self {
        case .cancel: "stop.circle"
        case .retry: "arrow.clockwise"
        case .open: "arrow.up.forward.app"
        case .showInFinder: "magnifyingglass"
        case .remove: "xmark"
        }
    }
}

/// One download: its file icon, name, progress and status line, and its actions as buttons, as a context menu and
/// as accessibility actions. A double click opens a finished file that can be reached. Equal rows skip their body,
/// so a progress tick redraws only its own row.
private struct DownloadRow: View, Equatable {
    static let height: CGFloat = 52
    static let spacing: CGFloat = 2

    let id: UUID
    let name: String
    let fileURL: URL?
    let row: DownloadRowModel
    let onAction: (UUID, DownloadRowModel.Action) -> Void
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.fileURL == rhs.fileURL && lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(name: name)
                // Dimmed once there is no file to open: neither running (Cancel) nor openable.
                .opacity(row.actions.contains(.cancel) || row.opensOnDoubleClick ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch row.progress {
                case .none:
                    EmptyView()
                case .determinate(let fraction):
                    ProgressView(value: fraction)
                        .controlSize(.small)
                case .indeterminate:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(row.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(row.actions, id: \.self) { action in
                    Button(action.title, systemImage: action.systemImage) { perform(action) }
                        .iconButtonStyle()
                        .frame(width: 20, height: 20)
                        .help(action.title)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(
            rowBackground(isSelected: false, isHovered: isHovered, cornerRadius: SidebarRowLabel.Metrics.cornerRadius))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            if row.opensOnDoubleClick { perform(.open) }
        }
        .contextMenu {
            ForEach(row.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(row.status)
        .accessibilityActions {
            ForEach(row.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
    }

    private func perform(_ action: DownloadRowModel.Action) { onAction(id, action) }
}

/// The icon Finder shows for a file of this name's type.
private struct FileIcon: View {
    let name: String

    var body: some View {
        Image(nsImage: FileIcons.icon(forExtension: (name as NSString).pathExtension.lowercased()))
            .resizable()
            .interpolation(.high)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
    }
}

/// File-type icons by extension, kept while memory allows, so rows do not ask the workspace on every redraw.
@MainActor
private enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(forExtension ext: String) -> NSImage {
        if let cached = cache.object(forKey: ext as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        cache.setObject(icon, forKey: ext as NSString)
        return icon
    }
}
