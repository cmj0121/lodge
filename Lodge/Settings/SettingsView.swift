import AppKit
import LodgeKit
import SwiftUI

/// The Settings window. `DownloadSettingsModel` writes each change to UserDefaults at once, and `DownloadManager`
/// reads them at each download, so they apply to the next one.
struct SettingsView: View {
    @State private var model: DownloadSettingsModel
    /// Bumped after the folder panel closes, so the menu redraws even when the selection did not change.
    @State private var menuRevision = 0

    init(model: DownloadSettingsModel = DownloadSettingsModel()) {
        _model = State(initialValue: model)
    }

    private enum Option: Hashable {
        case folder(DownloadFolderChoice.Selection)
        case other
    }

    var body: some View {
        Form {
            Section("Downloads") {
                Picker("Save downloads to:", selection: option) {
                    Text(DownloadFolderChoice.Selection.downloads.title).tag(Option.folder(.downloads))
                    if model.selection != .downloads {
                        Text(model.selection.title).tag(Option.folder(model.selection))
                    }
                    Divider()
                    Text("Other…").tag(Option.other)
                        .disabled(!model.isResolved)
                }
                .id(menuRevision)
                .accessibilityLabel("Save downloads to")
                .help(model.folder?.path(percentEncoded: false) ?? model.selection.title)
                if model.showsUnavailableNote {
                    Label(
                        "The chosen folder is unavailable; downloads go to Downloads.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Toggle("Ask where to save each file", isOn: $model.askEachTime)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.refresh() }
    }

    /// The menu always shows the model's selection; "Other…" only opens the folder panel.
    private var option: Binding<Option> {
        Binding {
            .folder(model.selection)
        } set: { option in
            switch option {
            case .folder(.downloads): model.useDownloads()
            case .folder: break
            case .other: chooseFolder()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for downloads."
        panel.directoryURL = model.folder
        // The panel's grant on the folder is held until Lodge quits, so the model can bookmark it afterwards.
        let chosen = panel.runModal() == .OK ? panel.url : nil
        Task {
            await model.useFolder(chosen)
            menuRevision += 1
        }
    }
}
