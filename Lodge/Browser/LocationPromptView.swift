import AppKit
import LodgeKit
import SwiftUI

/// The location prompt (D11): one wide field on a card over a dimmed window, its text selected on open, with this
/// workspace's suggestions listed under the field as it is typed in. Enter goes to the highlighted row, else to the
/// address or searches with the workspace's engine; Esc closes the list and drops a completion shown, keeping what
/// was typed, then closes the prompt, as does a click on the dimmed window.
struct LocationPromptView: View {
    let prompt: LocationPrompt
    let initialText: String
    let submit: (String) -> Void
    /// A row picked, with the words typed.
    let choose: (Suggestion, String) -> Void
    let makeSuggestions: () -> SuggestionModel
    let icon: (Suggestion) -> NSImage?
    let cancel: () -> Void
    @State private var suggestions: SuggestionModel?
    @State private var dropCompletionRequest = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: cancel)
                .accessibilityHidden(true)
            LocationPromptCard(
                prompt: prompt, initialText: initialText, suggestions: suggestions,
                dropCompletionRequest: dropCompletionRequest, icon: icon, submit: submit, choose: choose
            )
            .frame(width: 560)
            // The card grows down as rows come and go; its top stays put.
            .frame(height: LocationPromptCard.tallest, alignment: .top)
        }
        .background(EscapeKeyCatcher(action: escape))
        .onAppear { suggestions = makeSuggestions() }
    }

    private func escape() {
        if let suggestions, !suggestions.rows.isEmpty {
            suggestions.dismiss()
            dropCompletionRequest += 1
        } else {
            cancel()
        }
    }
}

private struct LocationPromptCard: View {
    let prompt: LocationPrompt
    let initialText: String
    let suggestions: SuggestionModel?
    /// Esc closed the list: the field drops its completion too.
    let dropCompletionRequest: Int
    let icon: (Suggestion) -> NSImage?
    let submit: (String) -> Void
    let choose: (Suggestion, String) -> Void
    @State private var text = ""
    @State private var isFocused = false
    @State private var focusRequest = 0

    private static let fieldHeight: CGFloat = 56
    private static let footerHeight: CGFloat = 38
    /// The card with every row listed.
    static let tallest = fieldHeight + footerHeight + 2 + SuggestionList.height(rows: SuggestionRanker.limit)

    private var destination: String {
        switch prompt {
        case .newTab: String(localized: "Opens in a new tab")
        case .current: String(localized: "Opens in this tab")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                AddressField(
                    text: $text, isEditing: $isFocused, placeholder: String(localized: "Search or enter an address"),
                    font: .systemFont(ofSize: 20), address: { _, _ in nil }, suggestions: suggestions,
                    completion: suggestions?.completion, icon: icon, choose: pick, focusRequest: focusRequest,
                    dropCompletionRequest: dropCompletionRequest, endsEditingOnSubmit: false,
                    submit: { submit(text) })
            }
            .padding(.horizontal, 18)
            .frame(height: Self.fieldHeight)
            if let suggestions, !suggestions.rows.isEmpty {
                Divider()
                SuggestionList(model: suggestions, icon: icon, choose: pick)
            }
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
            .frame(height: Self.footerHeight)
        }
        .floatingSurface(cornerRadius: 14, fill: .regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open Location")
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
        // ⌘T over ⌘L's prompt, or the reverse, starts over with the new destination's text.
        .onChange(of: prompt) { start() }
    }

    private func pick(_ row: Suggestion) { choose(row, suggestions?.words ?? text) }

    private func start() {
        suggestions?.dismiss()
        text = initialText
        focusRequest += 1
    }
}

/// ⏎ drawn as the shortcut overlay draws its key caps.
private struct ReturnKeyCap: View {
    var body: some View {
        Text(verbatim: "⏎")
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 20, minHeight: 20)
            .background(.fill.tertiary, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityLabel("Return")
    }
}
