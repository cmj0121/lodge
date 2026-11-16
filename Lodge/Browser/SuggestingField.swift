import AppKit
import LodgeKit
import SwiftUI

/// The rows of a `SuggestionModel`, the highlighted one marked; a click opens a row. Shared by the address bar's
/// panel and the location prompt. Icons come from `icon` only, which never fetches.
struct SuggestionList: View {
    let model: SuggestionModel
    let icon: (Suggestion) -> NSImage?
    let choose: (Suggestion) -> Void

    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 6

    /// The list's height for `rows` rows.
    static func height(rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + 2 * padding }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                Button {
                    choose(row)
                } label: {
                    SuggestionRow(row: row, icon: icon(row), isHighlighted: model.highlighted == index)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Self.padding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }
}

private struct SuggestionRow: View {
    let row: Suggestion
    let icon: NSImage?
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(verbatim: row.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let address {
                Text(verbatim: address)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let kind {
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: SuggestionList.rowHeight)
        .background(isHighlighted ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.title))
        .accessibilityValue(kind ?? "")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var symbol: String {
        switch row.kind {
        case .search: "magnifyingglass"
        case .openTab: "square.on.square"
        case .bookmark: "bookmark"
        case .history: "clock"
        }
    }

    /// What picking the row does or where it comes from; nil for the search row, whose title says it.
    private var kind: String? {
        switch row.kind {
        case .search: nil
        case .openTab: String(localized: "Switch to Tab")
        case .bookmark: String(localized: "Bookmark")
        case .history: String(localized: "History")
        }
    }

    /// The row's address without its scheme or `www.`; nil for the search row and when it equals the title.
    private var address: String? {
        guard let url = row.url else { return nil }
        var text = url.absoluteString
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text == row.title ? nil : text
    }
}

/// The address bar's suggestions in a borderless window under the field, a child of the field's window so it moves
/// and orders with it, placed again whenever the field's frame or the window's size changes. It never becomes key,
/// so the field keeps the keys while the list shows.
@MainActor
final class SuggestionPanel {
    private var panel: NSPanel?
    private var host: ClickThroughHostingView<SuggestionPopup>?
    /// What is shown, kept to place it again after a re-layout.
    private var shown: (list: SuggestionList, rows: Int, field: NSView)?
    private var observers: [NSObjectProtocol] = []

    isolated deinit { stopObserving() }

    /// Shows `list` under `field`, at least as wide as the field and sized for `rows` rows.
    func show(_ list: SuggestionList, rows: Int, under field: NSView) {
        guard let window = field.window else { return hide() }
        if shown?.field !== field || panel?.parent !== window { observe(field, in: window) }
        shown = (list, rows, field)
        let fieldFrame = window.convertToScreen(field.convert(field.bounds, to: nil))
        let width = max(fieldFrame.width + 20, 380)
        let height = SuggestionList.height(rows: rows)
        let frame = NSRect(x: fieldFrame.minX - 10, y: fieldFrame.minY - 6 - height, width: width, height: height)
        let popup = SuggestionPopup(list: list)
        if let panel, let host {
            host.rootView = popup
            panel.setFrame(frame, display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            return
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let host = ClickThroughHostingView(rootView: popup)
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.host = host
    }

    func hide() {
        stopObserving()
        shown = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        host = nil
    }

    /// Places the panel again when the field's frame changes (a toolbar or sidebar re-layout) or the window resizes,
    /// which a child window does not follow by itself.
    private func observe(_ field: NSView, in window: NSWindow) {
        stopObserving()
        field.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        let names: [(Notification.Name, AnyObject)] = [
            (NSView.frameDidChangeNotification, field),
            (NSWindow.didResizeNotification, window),
            (NSWindow.didEndLiveResizeNotification, window),
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeAgain() }
            }
        }
    }

    private func placeAgain() {
        guard let shown else { return }
        show(shown.list, rows: shown.rows, under: shown.field)
    }

    private func stopObserving() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

/// The list on the panel's rounded material.
struct SuggestionPopup: View {
    let list: SuggestionList

    var body: some View {
        list
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5) }
    }
}

/// Takes the first click though its window is never key, so one click on a row opens it.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
