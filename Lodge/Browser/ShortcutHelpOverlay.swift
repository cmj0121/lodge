import AppKit
import LodgeKit
import SwiftUI

/// Every catalog shortcut, grouped by menu, on a card over a dimmed window (D3). Esc, the close
/// button or a click on the dimmed window closes it.
struct ShortcutHelpOverlay: View {
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            ShortcutHelpCard(close: close)
                .fixedSize()
        }
        .background(EscapeKeyCatcher(action: close))
    }
}

private struct ShortcutHelpCard: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Close", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close (Esc)")
            }
            HStack(alignment: .top, spacing: 32) {
                ForEach(Self.columns.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Self.columns[column], id: \.menu) { group in
                            ShortcutGroup(menu: group.menu, shortcuts: group.shortcuts)
                        }
                    }
                    .frame(width: 236, alignment: .topLeading)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 22)
        .floatingSurface(cornerRadius: 14, fill: .regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
        .accessibilityAddTraits(.isModal)
    }

    /// The catalog's groups in menu order, cut into two columns where the row counts come closest.
    private static let columns: [[(menu: ShortcutMenu, shortcuts: [Shortcut])]] = {
        let groups = ShortcutCatalog.grouped
        let total = groups.reduce(0) { $0 + $1.shortcuts.count }
        var best = (cut: groups.count, imbalance: total)
        var left = 0
        for cut in groups.indices.dropFirst() {
            left += groups[cut - 1].shortcuts.count
            let imbalance = abs(total - 2 * left)
            if imbalance < best.imbalance { best = (cut, imbalance) }
        }
        return [Array(groups[..<best.cut]), Array(groups[best.cut...])].filter { !$0.isEmpty }
    }()
}

private struct ShortcutGroup: View {
    let menu: ShortcutMenu
    let shortcuts: [Shortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(menu.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(shortcuts) { shortcut in
                ShortcutRow(shortcut: shortcut)
            }
        }
    }
}

/// The command's title, and its key and any alias as key caps: "⌘ = or ⌘ +".
private struct ShortcutRow: View {
    let shortcut: Shortcut

    private var combos: [KeyCombo] { [shortcut.combo] + shortcut.aliases }

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(combos.indices, id: \.self) { index in
                    if index > 0 {
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    KeyCaps(combo: combos[index])
                }
                if let note = shortcut.note { Text("(\(note))").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(
            combos.map(\.display).joined(separator: " or ") + (shortcut.note.map { " (\($0))" } ?? ""))
    }
}

/// One cap per glyph of the combo's display string.
private struct KeyCaps: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(combo.display.enumerated()), id: \.offset) { _, glyph in
                Text(String(glyph))
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5)
                    }
            }
        }
    }
}
