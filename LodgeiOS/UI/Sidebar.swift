import LodgeKit
import SwiftUI

/// iPad: the sidebar beside the page, always on screen. Expanded it is the full tabs panel; collapsed it is a narrow
/// rail of letter tiles, one per pin and then per loose tab. A narrow window shows the rail without changing what is
/// remembered, and the toggle there expands the panel only until the window widens again.
struct Sidebar: View {
    @AppStorage("sidebarCollapsed") private var collapsed = false
    /// Whether the window is too narrow for the panel beside the page.
    let isNarrow: Bool
    @State private var expandedWhileNarrow = false

    var body: some View {
        let showsRail = isNarrow ? !expandedWhileNarrow : collapsed
        let toggle = Button(
            showsRail ? "Expand Sidebar" : "Collapse Sidebar", systemImage: "sidebar.left"
        ) {
            withAnimation(.snappy) {
                if isNarrow { expandedWhileNarrow.toggle() } else { collapsed.toggle() }
            }
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        Group {
            if showsRail {
                SidebarRail(toggle: toggle)
                    .frame(width: 68)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                SidebarPanel(toggle: toggle)
                    .frame(width: 300)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground))
        .onChange(of: isNarrow) { expandedWhileNarrow = false }
    }
}

/// The full panel: the workspace's name and its controls above today's pins and tabs.
private struct SidebarPanel<Toggle: View>: View {
    @Environment(AppModel.self) private var model
    let toggle: Toggle

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.active.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ControlBar {
                    HStack(spacing: 0) {
                        WorkspaceMenu().railButton()
                        Button("New Tab", systemImage: "plus") { model.newTab() }.railButton()
                        toggle.railButton()
                    }
                    .padding(.horizontal, 4)
                    .controlGlass()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            TabsPanel()
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
        }
    }
}

/// The collapsed rail: the workspace, a new tab, and a tile per pin and per loose tab, scrolling when they overflow.
private struct SidebarRail<Toggle: View>: View {
    @Environment(AppModel.self) private var model
    let toggle: Toggle

    var body: some View {
        let selected = model.selectedTab?.id
        let loose = model.looseTabs
        VStack(spacing: 10) {
            GlassEffectContainer {
                VStack(spacing: 0) {
                    toggle.railButton()
                    WorkspaceMenu().railButton()
                    Button("New Tab", systemImage: "plus") { model.newTab() }.railButton()
                }
                .padding(.vertical, 4)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
            }
            .padding(.top, 8)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.pins) { pin in
                        let tab = model.tab(for: pin)
                        Button {
                            model.openPin(pin)
                        } label: {
                            LetterTile(
                                letter: Self.letter(host: (tab?.url ?? pin.url).host(percentEncoded: false), title: pin.title),
                                isSelected: tab != nil && tab?.id == selected, isOpen: tab != nil)
                        }
                        .accessibilityLabel(pin.title)
                        .help(pin.title)
                        .contextMenu {
                            if let tab { Button("Close Tab", systemImage: "xmark") { model.close(tab.id) } }
                            Button("Unpin", systemImage: "pin.slash", role: .destructive) { model.unpin(pin.id) }
                        }
                    }
                    if !model.pins.isEmpty, !loose.isEmpty {
                        Divider().frame(width: 28).padding(.vertical, 2)
                    }
                    ForEach(loose) { tab in
                        let title = model.title(for: tab)
                        Button {
                            model.select(tab.id)
                        } label: {
                            LetterTile(
                                letter: tab.url == nil
                                    ? nil : Self.letter(host: tab.url?.host(percentEncoded: false), title: title),
                                isSelected: tab.id == selected, isOpen: true)
                        }
                        .accessibilityLabel(title)
                        .help(title)
                        .contextMenu {
                            if model.canPin(tab) { Button("Pin", systemImage: "pin") { model.pin(tab.id) } }
                            Button("Close Tab", systemImage: "xmark", role: .destructive) { model.close(tab.id) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The first letter of the host, past a leading "www.", or of the title when there is no host.
    private static func letter(host: String?, title: String) -> String {
        var name = host ?? ""
        if name.hasPrefix("www.") { name.removeFirst(4) }
        if name.isEmpty { name = title }
        return name.first.map { String($0).uppercased() } ?? "•"
    }
}

/// A page in the rail: its letter, or a plus for a blank tab, on a tinted square — stronger when selected, faint for
/// a pin with no open tab.
private struct LetterTile: View {
    let letter: String?
    let isSelected: Bool
    let isOpen: Bool

    var body: some View {
        Group {
            if let letter {
                Text(letter).font(.title3.bold())
            } else {
                Image(systemName: "plus").font(.title3.weight(.semibold))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        .frame(width: 44, height: 44)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.15)), in: .rect(cornerRadius: 12))
        .opacity(isOpen ? 1 : 0.45)
        .contentShape(.rect(cornerRadius: 12))
    }
}

extension View {
    /// An icon-only control in the sidebar's glass, square enough to hit with a finger.
    fileprivate func railButton() -> some View {
        labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}
