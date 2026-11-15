import LodgeKit
import SwiftUI

/// What the workspace sheet is open for (D8): a new workspace asks for a name, an icon and a colour, a rename for
/// the name alone, a change of icon for the icon and colour.
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

    /// Whether the sheet offers the icon grid and colour row: New Workspace and Change Icon do, Rename does not, and
    /// nothing is offered for Anonymous, which keeps its icon and colour.
    static func offersIconAndColor(_ editor: WorkspaceEditor, target: Workspace?) -> Bool {
        if target?.kind == .anonymous { return false }
        if case .rename = editor { return false } else { return true }
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
    @State private var color: WorkspaceColor?
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

    /// Anonymous keeps its name, icon and colour; a sheet opened for it anyway says so and offers nothing to change.
    private var isFixed: Bool { target?.kind == .anonymous }

    private var asksName: Bool {
        if isFixed { return false }
        if case .changeIcon = editor { return false } else { return true }
    }

    private var asksSymbol: Bool { WorkspaceSheet.offersIconAndColor(editor, target: target) }

    private var validation: Result<String, WorkspaceList.EditError> {
        coordinator.workspaces.validate(name: name, renaming: target?.id)
    }

    private var message: String? {
        if let refused { return WorkspaceForm.message(for: refused, name: name) }
        guard asksName, case .failure(let error) = validation, isNameEdited || error != .emptyName else { return nil }
        return WorkspaceForm.message(for: error, name: name)
    }

    private var canCommit: Bool {
        if case .create = editor {} else if target == nil || isFixed { return false }
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
                if isFixed {
                    Text(WorkspaceForm.message(for: .anonymousIsFixed, name: name))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if asksName { nameField }
                if asksSymbol {
                    SymbolGrid(selection: $symbol, focusesOnAppear: !asksName)
                    ColorRow(selection: $color)
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
        .workspaceTint(asksSymbol ? color : target?.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        .onChange(of: editor) { start() }
        .onChange(of: symbol) { refused = nil }
        .onChange(of: color) { refused = nil }
    }

    /// The workspace as the bar will show it, next to what the sheet does.
    private var header: some View {
        HStack(spacing: 14) {
            PreviewIcon(symbol: asksSymbol ? symbol : target?.symbol ?? symbol)
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
        color = target?.color
        refused = nil
        isNameEdited = false
        isNameFocused = asksName
    }

    private func commit() {
        guard canCommit else { return }
        do {
            switch editor {
            case .create:
                try coordinator.create(name: name, symbol: symbol, color: color)
            case .rename(let id):
                try coordinator.rename(id, to: name)
            case .changeIcon(let id):
                try coordinator.setSymbol(id, symbol)
                try coordinator.setColor(id, color)
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
    @Environment(\.workspaceTint) private var tint

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
                    .strokeBorder(focusRing(tint).opacity(isFocused ? 0.7 : 0), lineWidth: 2)
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
        let index = all.firstIndex(of: selection) ?? 0
        selection = all[
            WorkspaceForm.symbolIndex(
                from: index, moving: WorkspaceForm.Move(direction), columns: WorkspaceSheetCard.columns,
                count: all.count)]
    }
}

extension WorkspaceForm.Move {
    fileprivate init(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        @unknown default: self = .right
        }
    }
}

/// The ring round a focused grid or row, and the selected icon's fill: the chosen colour, else the system accent.
private func focusRing(_ tint: WorkspaceColor?) -> Color {
    tint?.color ?? .accentColor
}

/// The icon tile as the bar will show it: the selected-row fill with the colour's hairline, washed and drawn in the
/// chosen colour.
private struct PreviewIcon: View {
    let symbol: String
    @Environment(\.workspaceTint) private var tint

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(tint.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.primary))
            .frame(width: 48, height: 48)
            .background(WorkspaceWash().clipShape(RoundedRectangle(cornerRadius: 12)))
            .background(rowBackground(isSelected: true, isHovered: false, cornerRadius: 12))
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.2), value: tint)
            .accessibilityHidden(true)
    }
}

/// None and the eight swatches on one row, as wide as the icon grid. Click one, or focus the row and walk it with
/// the arrow keys; VoiceOver reads each by name and marks the chosen one.
private struct ColorRow: View {
    @Binding var selection: WorkspaceColor?
    @FocusState private var isFocused: Bool

    /// None first.
    private static let choices: [WorkspaceColor?] = [nil] + WorkspaceColor.palette.map(Optional.some)
    private static let cell: CGFloat = 34
    private static let spacing: CGFloat = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Color")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            HStack(spacing: Self.spacing) {
                ForEach(Self.choices, id: \.self) { choice in
                    ColorCell(color: choice, isSelected: choice == selection) { selection = choice }
                        .frame(width: Self.cell, height: Self.cell)
                }
            }
            .padding(4)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focusRing(selection).opacity(isFocused ? 0.7 : 0), lineWidth: 2)
            }
            .onMoveCommand(perform: move)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Color")
            .accessibilityValue(ColorCell.label(for: selection))
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let all = Self.choices
        let index = all.firstIndex(of: selection) ?? 0
        selection = all[
            WorkspaceForm.symbolIndex(
                from: index, moving: WorkspaceForm.Move(direction), columns: all.count, count: all.count)]
    }
}

private struct ColorCell: View {
    let color: WorkspaceColor?
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false

    static func label(for color: WorkspaceColor?) -> String { color?.label ?? "None" }

    var body: some View {
        Button(action: choose) {
            ZStack {
                rowBackground(isSelected: false, isHovered: isHovered && !isSelected, cornerRadius: 8)
                if isSelected {
                    Circle()
                        .strokeBorder((color?.color ?? .secondary).opacity(0.85), lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
                swatch
                    .frame(width: 20, height: 20)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(Self.label(for: color))
        .accessibilityLabel(Self.label(for: color))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var swatch: some View {
        if let color {
            Circle()
                .fill(color.color)
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
        } else {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1.5)
                .overlay {
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 1.5)
                        .rotationEffect(.degrees(45))
                }
                .clipShape(Circle())
        }
    }
}

private struct SymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false
    @Environment(\.workspaceTint) private var tint

    var body: some View {
        Button(action: choose) {
            Image(systemName: symbol)
                .symbolVariant(isSelected ? .fill : .none)
                .font(.system(size: 16))
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(tint?.selectedForeground ?? .white) : AnyShapeStyle(.secondary))
                .frame(width: 38, height: 34)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8).fill(focusRing(tint))
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
