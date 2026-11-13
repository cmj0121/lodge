import SwiftUI

/// Find in page, floating over the page's top-right corner so it never moves the page.
struct FindPopup: View {
    let pane: BrowserPane
    @Bindable var window: WindowState
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find on page", text: $window.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit(pane.findNext)
                .task(id: window.findText) {
                    guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                    pane.findIfChanged()
                }
                .onExitCommand(perform: pane.hideFind)
            if window.findMissed {
                Text("Not found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ControlGroup {
                Button("Previous", systemImage: "chevron.up", action: pane.findPrevious)
                    .help("Previous match")
                Button("Next", systemImage: "chevron.down", action: pane.findNext)
                    .help("Next match")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .disabled(window.findText.isEmpty)
            Button("Done", action: pane.hideFind)
        }
        .padding(8)
        .floatingSurface(cornerRadius: 8, fill: .regularMaterial)
        .onAppear { isFocused = true }
        .onChange(of: window.findFocusRequest) { isFocused = true }
    }
}
