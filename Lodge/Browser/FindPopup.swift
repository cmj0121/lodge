import SwiftUI

/// Find in page, floating over the page's top-right corner so it never moves the page.
struct FindPopup: View {
    @Bindable var model: BrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find on page", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($isFocused)
                .onSubmit(model.findNext)
                .task(id: model.findText) {
                    guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                    model.findIfChanged()
                }
                .onExitCommand(perform: model.hideFind)
            if model.findMissed {
                Text("Not found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ControlGroup {
                Button("Previous", systemImage: "chevron.up", action: model.findPrevious)
                    .help("Previous match")
                Button("Next", systemImage: "chevron.down", action: model.findNext)
                    .help("Next match")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            .disabled(model.findText.isEmpty)
            Button("Done", action: model.hideFind)
        }
        .padding(8)
        .floatingSurface(cornerRadius: 8, fill: .regularMaterial)
        .onAppear { isFocused = true }
        .onChange(of: model.findFocusRequest) { isFocused = true }
    }
}
