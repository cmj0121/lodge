import LodgeKit
import SwiftUI

/// What the workspace sheet is open for (D8): a new workspace asks for a name and an icon, a rename for the name
/// alone, a change of icon for the icon alone.
enum WorkspaceEditor: Equatable {
    case create
    case rename(UUID)
    case changeIcon(UUID)
}

/// The workspace sheet: a card over the dimmed window, as the location prompt is. Esc, Cancel or a click on the
/// dimmed window closes it; Return commits once the name is valid.
struct WorkspaceSheet: View {
    let coordinator: WorkspaceCoordinator
    let editor: WorkspaceEditor
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            WorkspaceSheetCard(coordinator: coordinator, editor: editor, close: close)
                .frame(width: WorkspaceSheetCard.width)
        }
        .background(EscapeKeyCatcher(action: close))
    }
}

struct WorkspaceSheetCard: View {
    static let width: CGFloat = 392
    fileprivate static let columns = 8

    let coordinator: WorkspaceCoordinator
    let editor: WorkspaceEditor
    let close: () -> Void
    @State private var name = ""
    @State private var symbol = WorkspaceSymbols.defaultForNew
    /// Set once the name has been typed in, so a new sheet does not open on an error.
    @State private var isNameEdited = false
    /// What the coordinator refused on commit; cleared by the next edit.
    @State private var refused: WorkspaceList.EditError?
    @FocusState private var isNameFocused: Bool

    private var target: Workspace? {
        switch editor {
        case .create: nil
        case .rename(let id), .changeIcon(let id): coordinator.workspaces[id]
        }
    }

    private var asksName: Bool {
        if case .changeIcon = editor { false } else { true }
    }

    private var asksSymbol: Bool {
        if case .rename = editor { false } else { true }
    }

    private var validation: Result<String, WorkspaceList.EditError> {
        coordinator.workspaces.validate(name: name, renaming: target?.id)
    }

    private var message: String? {
        if let refused { return WorkspaceForm.message(for: refused, name: name) }
        guard asksName, case .failure(let error) = validation, isNameEdited || error != .emptyName else { return nil }
        return WorkspaceForm.message(for: error, name: name)
    }

    private var canCommit: Bool {
        if case .create = editor {} else if target == nil { return false }
        if asksName, case .failure = validation { return false }
        return true
    }

    private var title: String {
        switch editor {
        case .create: "New Workspace"
        case .rename: "Rename Workspace"
        case .changeIcon: "Change Icon"
        }
    }

    private var commitTitle: String {
        switch editor {
        case .create: "Create"
        case .rename: "Rename"
        case .changeIcon: "Change Icon"
        }
    }

    /// The name the preview tile shows: what is typed, else the workspace's own name, else a stand-in.
    private var previewName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if asksName { return typed.isEmpty ? "Untitled" : typed }
        return target?.name ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if asksName { nameField }
                if asksSymbol {
                    SymbolGrid(selection: $symbol, focusesOnAppear: !asksName)
                }
            }
            .padding(18)
            Divider()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(commitTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
            .controlSize(.large)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .floatingSurface(cornerRadius: 14, fill: .regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        .onChange(of: editor) { start() }
        .onChange(of: symbol) { refused = nil }
    }

    /// The workspace as the bar will show it, next to what the sheet does.
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .symbolVariant(.fill)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(rowBackground(isSelected: true, isHovered: false, cornerRadius: 12))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(previewName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Name", text: typedName, prompt: Text("Work, Personal, Side project…"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($isNameFocused)
                .onSubmit(commit)
                .accessibilityLabel("Name")
                .accessibilityHint(message ?? "")
            // Always one line tall, so the card does not jump as the message comes and goes.
            Text(message ?? " ")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(1)
                .accessibilityHidden(message == nil)
        }
    }

    /// The name as the field edits it: typing marks it edited and clears a refusal.
    private var typedName: Binding<String> {
        Binding(
            get: { name },
            set: {
                name = $0
                isNameEdited = true
                refused = nil
            })
    }

    private func start() {
        name = target?.name ?? ""
        symbol = target?.symbol ?? WorkspaceSymbols.defaultForNew
        refused = nil
        isNameEdited = false
        isNameFocused = asksName
    }

    private func commit() {
        guard canCommit else { return }
        do {
            switch editor {
            case .create:
                try coordinator.create(name: name, symbol: symbol)
            case .rename(let id):
                try coordinator.rename(id, to: name)
            case .changeIcon(let id):
                try coordinator.setSymbol(id, symbol)
            }
            close()
        } catch {
            refused = error
        }
    }
}

/// The curated symbols, eight to a row. Click one, or focus the grid and walk it with the arrow keys; VoiceOver
/// reads each by name and marks the chosen one.
private struct SymbolGrid: View {
    @Binding var selection: String
    /// Change Icon has no name field, so the grid takes the keys as it opens.
    let focusesOnAppear: Bool
    @FocusState private var isFocused: Bool

    private static let cell: CGFloat = 38
    private static let spacing: CGFloat = 6
    private static let columns = Array(
        repeating: GridItem(.fixed(cell), spacing: spacing), count: WorkspaceSheetCard.columns)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Self.spacing) {
                ForEach(WorkspaceSymbols.all, id: \.self) { symbol in
                    SymbolCell(symbol: symbol, isSelected: symbol == selection) { selection = symbol }
                }
            }
            .padding(4)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.7 : 0), lineWidth: 2)
            }
            .onMoveCommand(perform: move)
            .onAppear { if focusesOnAppear { isFocused = true } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Icon")
            .accessibilityValue(WorkspaceSymbols.label(for: selection))
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let all = WorkspaceSymbols.all
        let step: WorkspaceForm.Move =
            switch direction {
            case .left: .left
            case .right: .right
            case .up: .up
            case .down: .down
            @unknown default: .right
            }
        let index = all.firstIndex(of: selection) ?? 0
        selection = all[
            WorkspaceForm.symbolIndex(from: index, moving: step, columns: WorkspaceSheetCard.columns, count: all.count)]
    }
}

private struct SymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            Image(systemName: symbol)
                .symbolVariant(isSelected ? .fill : .none)
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 38, height: 34)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
                    } else {
                        rowBackground(isSelected: false, isHovered: isHovered, cornerRadius: 8)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(WorkspaceSymbols.label(for: symbol))
        .accessibilityLabel(WorkspaceSymbols.label(for: symbol))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
