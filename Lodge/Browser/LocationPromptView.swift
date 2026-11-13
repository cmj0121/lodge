import LodgeKit
import SwiftUI

/// The location prompt (D11): one wide field on a card over a dimmed window, its text selected on open. Enter goes
/// to the address or searches DuckDuckGo; Esc or a click on the dimmed window closes it.
struct LocationPromptView: View {
    let prompt: LocationPrompt
    let initialText: String
    let submit: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            LocationPromptCard(prompt: prompt, initialText: initialText, submit: submit)
                .frame(width: 560)
        }
        .background(EscapeKeyCatcher(action: cancel))
    }
}

private struct LocationPromptCard: View {
    let prompt: LocationPrompt
    let initialText: String
    let submit: (String) -> Void
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    private var destination: String {
        switch prompt {
        case .newTab: "Opens in a new tab"
        case .current: "Opens in this tab"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search or enter an address", text: $text, selection: $selection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($isFocused)
                    .onSubmit { submit(text) }
                    .accessibilityLabel("Address")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Divider()
            HStack(spacing: 6) {
                Text(destination)
                Spacer(minLength: 8)
                ReturnKeyCap()
                Text("to go")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .floatingSurface(cornerRadius: 14, fill: .regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open Location")
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        // ⌘T over ⌘L's prompt, or the reverse, starts over with the new destination's text.
        .onChange(of: prompt) { start() }
    }

    private func start() {
        text = initialText
        isFocused = true
        selection = TextSelection(range: text.startIndex..<text.endIndex)
    }
}

/// ⏎ drawn as the shortcut overlay draws its key caps.
private struct ReturnKeyCap: View {
    var body: some View {
        Text("⏎")
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 20, minHeight: 20)
            .background(.fill.tertiary, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityLabel("Return")
    }
}
