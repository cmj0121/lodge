import AppKit
import LodgeKit
import SwiftUI

/// The engines added to one workspace, each with Edit and Remove, then Add Engine…; built-ins are not listed, so they
/// offer neither. Settings › Search shows Default's, the workspace sheet a custom workspace's or Anonymous's. Each
/// change is saved at once; an entry `SearchEngine.validate` refuses is not saved and says why under its fields.
/// Removing a Default engine that other workspaces search with asks first and names them. While an engine is being
/// added or edited, Return saves it and Esc drops it.
struct SearchEngineEditor: View {
    let coordinator: WorkspaceCoordinator
    let workspace: UUID
    /// True while an engine is being added or edited; set false from outside to drop the draft. A host with its own
    /// Return and Esc (the workspace sheet) lets them go while it is true.
    @Binding var isDrafting: Bool
    /// Called after an engine is added, changed or removed, so a picker can drop a choice that no longer exists.
    var changed: () -> Void = {}
    /// The engine being edited, or a new one when its id is nil.
    @State private var draft: Draft?

    private struct Draft: Equatable {
        var id: String?
        var name = ""
        var template = ""
        var refused: SearchEngine.EditError?
    }

    private var engines: [SearchEngine] { coordinator.search[workspace].engines }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Added engines")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if engines.isEmpty && draft == nil {
                Text("None yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(engines) { engine in
                if draft?.id == engine.id { form } else { row(engine) }
            }
            if let draft, draft.id == nil {
                form
            } else {
                Button("Add Engine…") { draft = Draft() }
                    .disabled(draft != nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Added engines")
        .onChange(of: workspace) { draft = nil }
        .onChange(of: draft != nil) { isDrafting = draft != nil }
        .onChange(of: isDrafting) { if !isDrafting { draft = nil } }
    }

    private func row(_ engine: SearchEngine) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: engine.name)
                    .lineLimit(1)
                Text(verbatim: engine.template)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button {
                draft = Draft(id: engine.id, name: engine.name, template: engine.template)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .disabled(draft != nil)
            .help("Edit")
            .accessibilityLabel("Edit \(engine.name)")
            Button {
                remove(engine)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(draft != nil)
            .help("Remove")
            .accessibilityLabel("Remove \(engine.name)")
        }
        .accessibilityElement(children: .contain)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: field(\.name), prompt: Text("Example"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Name")
            TextField(
                "Search address", text: field(\.template),
                prompt: Text(verbatim: "https://example.com/search?q=%s"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Search address")
                .accessibilityHint(draft?.refused?.message ?? "")
            Text((draft?.refused ?? .missingPlaceholder).message)
                .font(.callout)
                .foregroundStyle(draft?.refused == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(draft?.id == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 4)
    }

    /// A draft field as its text field edits it: typing clears the refusal.
    private func field(_ key: WritableKeyPath<Draft, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: key] ?? "" },
            set: {
                draft?[keyPath: key] = $0
                draft?.refused = nil
            })
    }

    private func save() {
        guard let current = draft else { return }
        do {
            if let id = current.id {
                try coordinator.updateSearchEngine(id, name: current.name, template: current.template, in: workspace)
            } else {
                try coordinator.addSearchEngine(name: current.name, template: current.template, to: workspace)
            }
            draft = nil
            changed()
        } catch {
            draft?.refused = error
        }
    }

    /// Removes at once unless other workspaces search with this Default engine; then asks first, naming them and the
    /// engine each will search with once it is gone.
    private func remove(_ engine: SearchEngine) {
        let dependents = workspace == Workspace.defaultID ? coordinator.searchDependents(of: engine.id) : []
        let perform = {
            try? coordinator.removeSearchEngine(engine.id, from: workspace)
            changed()
        }
        guard !dependents.isEmpty else { return perform() }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(engine.name)”?")
        alert.informativeText = Self.fallbackText(for: engine, dependents: dependents, in: coordinator.search)
        alert.addButton(withTitle: String(localized: "Remove")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        let handle = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { perform() }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    /// Who searches with the engine, then who will search with what once it is removed, workspaces grouped by the
    /// engine they fall back to, in bar order.
    private static func fallbackText(for engine: SearchEngine, dependents: [Workspace], in search: SearchSettings)
        -> String
    {
        var after = search
        try? after.remove(engine.id, from: Workspace.defaultID)
        var groups: [(engine: SearchEngine, names: [String])] = []
        for workspace in dependents {
            let fallback = after.catalog(for: workspace).engine
            if let index = groups.firstIndex(where: { $0.engine == fallback }) {
                groups[index].names.append(workspace.name)
            } else {
                groups.append((fallback, [workspace.name]))
            }
        }
        let users = ListFormatter.localizedString(byJoining: dependents.map(\.name))
        let lines = groups.map { group in
            let names = ListFormatter.localizedString(byJoining: group.names)
            return String(localized: "\(names) will then search with \(group.engine.name).")
        }
        return ([String(localized: "\(users) search with it.")] + lines).joined(separator: " ")
    }
}
