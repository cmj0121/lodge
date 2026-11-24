import LodgeKit
import SwiftUI

/// Makes a workspace, or changes the one on screen: its name (custom only), icon and color (all but Anonymous) and
/// appearance (all), with Delete for a custom one. The rules are the Mac's (`WorkspaceList`).
struct WorkspaceEditor: View {
    enum Mode: Identifiable {
        case create
        case edit(Workspace)

        var id: UUID? {
            if case .edit(let workspace) = self { workspace.id } else { nil }
        }
    }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = WorkspaceSymbols.defaultForNew
    @State private var color: WorkspaceColor?
    @State private var appearance = WorkspaceAppearance.system
    @State private var isNameEdited = false
    @State private var refused: WorkspaceList.EditError?
    @State private var asksDelete = false

    private var target: Workspace? {
        if case .edit(let workspace) = mode { workspace } else { nil }
    }

    private var asksName: Bool { target.map { $0.kind == .custom } ?? true }
    private var asksSymbol: Bool { target?.kind != .anonymous }

    private var validation: Result<String, WorkspaceList.EditError> {
        model.workspaces.validate(name: name, renaming: target?.id)
    }

    private var message: String? {
        if let refused { return WorkspaceForm.message(for: refused, name: name) }
        guard asksName, case .failure(let error) = validation, isNameEdited || error != .emptyName else { return nil }
        return WorkspaceForm.message(for: error, name: name)
    }

    private var canCommit: Bool {
        guard asksName else { return true }
        if case .failure = validation { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if asksName {
                        TextField("Name", text: $name)
                            .onChange(of: name) {
                                isNameEdited = true
                                refused = nil
                            }
                    } else {
                        LabeledContent("Name", value: target?.name ?? "")
                    }
                } footer: {
                    if let message { Text(message).foregroundStyle(.red) }
                }
                if asksSymbol {
                    Section("Icon") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
                            ForEach(WorkspaceSymbols.all, id: \.self) { candidate in
                                Button {
                                    symbol = candidate
                                } label: {
                                    Image(systemName: candidate)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            candidate == symbol ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.clear),
                                            in: .rect(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(candidate == symbol ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Color") {
                        HStack(spacing: 10) {
                            swatch(nil)
                            ForEach(WorkspaceColor.palette, id: \.self) { swatch($0) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag(WorkspaceAppearance.system)
                        Text("Light").tag(WorkspaceAppearance.light)
                        Text("Dark").tag(WorkspaceAppearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if let target, target.kind == .custom {
                    Section {
                        Button("Delete Workspace", role: .destructive) { asksDelete = true }
                    }
                }
            }
            .navigationTitle(target == nil ? LocalizedStringKey("New Workspace") : "Edit Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target == nil ? LocalizedStringKey("Create") : "Save") { commit() }
                        .disabled(!canCommit)
                }
            }
            .confirmationDialog(
                "Delete “\(target?.name ?? "")”?", isPresented: $asksDelete, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let target { model.deleteWorkspace(target.id) }
                    dismiss()
                }
            } message: {
                Text("Its tabs close, and its bookmarks, history, sign-ins and site data are deleted. This cannot be undone.")
            }
        }
        .onAppear {
            guard let target else { return }
            name = target.name
            symbol = target.symbol
            color = target.color
            appearance = target.appearance
            isNameEdited = false
        }
    }

    private func swatch(_ candidate: WorkspaceColor?) -> some View {
        Button {
            color = candidate
        } label: {
            Circle()
                .fill(candidate?.tint ?? Color.secondary.opacity(0.25))
                .frame(width: 26, height: 26)
                .overlay {
                    if candidate == color {
                        Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                    }
                }
                .overlay {
                    if candidate == nil { Image(systemName: "slash.circle").foregroundStyle(.secondary) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate?.label ?? String(localized: "None"))
        .accessibilityAddTraits(candidate == color ? .isSelected : [])
    }

    private func commit() {
        do {
            if let target {
                try model.editWorkspace(target.id, name: name, symbol: symbol, color: color, appearance: appearance)
            } else {
                try model.createWorkspace(name: name, symbol: symbol, color: color, appearance: appearance)
            }
            dismiss()
        } catch {
            refused = error
        }
    }
}
