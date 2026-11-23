import LodgeKit
import SwiftUI

/// The workspace's pins (Default's, shared by every workspace) and its loose tabs; a pin with an open tab shows it.
/// On iPad it is the sidebar; on iPhone, the tabs sheet, which `onPick` closes.
struct TabsPanel: View {
    @Environment(AppModel.self) private var model
    var onPick: () -> Void = {}

    var body: some View {
        let selected = model.selectedTab?.id
        let pinIDs = Set(model.pins.map(\.id))
        let loose = model.activeTabs.filter { tab in tab.link.map { !pinIDs.contains($0) } ?? true }
        List {
            if let summary = model.active.summary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if !model.pins.isEmpty {
                Section("Pins") {
                    ForEach(model.pins) { pin in
                        let tab = model.tab(for: pin)
                        Button {
                            model.openPin(pin)
                            onPick()
                        } label: {
                            Row(
                                title: pin.title, subtitle: (tab?.url ?? pin.url).host(percentEncoded: false),
                                symbol: "pin.fill", isOpen: tab != nil)
                        }
                        .listRowBackground(tab?.id == selected && tab != nil ? Color.accentColor.opacity(0.18) : nil)
                        .swipeActions {
                            if let tab {
                                Button("Close Tab", systemImage: "xmark") { model.close(tab.id) }
                            }
                            Button("Unpin", systemImage: "pin.slash", role: .destructive) { model.unpin(pin.id) }
                        }
                        .contextMenu {
                            if let tab { Button("Close Tab", systemImage: "xmark") { model.close(tab.id) } }
                            Button("Unpin", systemImage: "pin.slash", role: .destructive) { model.unpin(pin.id) }
                        }
                    }
                    .onMove { model.movePins(fromOffsets: $0, toOffset: $1) }
                }
            }
            Section("Tabs") {
                ForEach(loose) { tab in
                    Button {
                        model.select(tab.id)
                        onPick()
                    } label: {
                        Row(
                            title: tab.url == nil && tab.title.isEmpty ? String(localized: "New Tab") : tab.displayTitle,
                            subtitle: tab.url?.host(percentEncoded: false), symbol: "globe", isOpen: true)
                    }
                    .listRowBackground(tab.id == selected ? Color.accentColor.opacity(0.18) : nil)
                    .swipeActions {
                        Button("Close Tab", systemImage: "xmark", role: .destructive) { model.close(tab.id) }
                    }
                    .contextMenu {
                        if model.canPin(tab) { Button("Pin", systemImage: "pin") { model.pin(tab.id) } }
                        Button("Close Tab", systemImage: "xmark", role: .destructive) { model.close(tab.id) }
                    }
                }
                .onMove { model.move(loose, fromOffsets: $0, toOffset: $1) }
                if loose.isEmpty {
                    Text("No open tabs")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct Row: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// What a blank tab shows: the pins, one tap away.
struct StartPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Label(model.active.name, systemImage: model.active.symbol)
                    .font(.title2.bold())
                    .foregroundStyle(.tint)
                    .padding(.top, 48)
                if model.pins.isEmpty {
                    Text("Pin a tab to keep it one tap away in every workspace.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 16)], spacing: 16) {
                        ForEach(model.pins) { pin in
                            Button {
                                model.openPin(pin)
                            } label: {
                                VStack(spacing: 6) {
                                    Text(pin.title.first.map(String.init)?.uppercased() ?? "•")
                                        .font(.title2.bold())
                                        .foregroundStyle(.tint)
                                        .frame(width: 56, height: 56)
                                        .background(.tint.opacity(0.15), in: .rect(cornerRadius: 14))
                                    Text(pin.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}
