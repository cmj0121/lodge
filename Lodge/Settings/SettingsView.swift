import AppKit
import LodgeKit
import SwiftUI
import os

/// The Settings window. `DownloadSettingsModel` writes each change to UserDefaults at once, and `DownloadManager`
/// reads them at each download, so they apply to the next one.
struct SettingsView: View {
    @State private var model: DownloadSettingsModel
    /// Bumped after the folder panel closes, so the menu redraws even when the selection did not change.
    @State private var menuRevision = 0
    /// Whether Lodge opens http and https links; nil until first read.
    @State private var isDefaultBrowser: Bool?
    @State private var isMakingDefault = false

    init(model: DownloadSettingsModel = DownloadSettingsModel()) {
        _model = State(initialValue: model)
    }

    private enum Option: Hashable {
        case folder(DownloadFolderChoice.Selection)
        case other
    }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Default browser") {
                    if isDefaultBrowser == true {
                        Label("Lodge is your default browser", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Lodge the Default Browser", action: makeDefaultBrowser)
                            .disabled(isDefaultBrowser == nil || isMakingDefault)
                    }
                }
            }
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
        .onAppear { isDefaultBrowser = DefaultBrowser.isLodge }
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

    /// macOS asks the user to confirm each scheme; the status is read again whatever they chose.
    private func makeDefaultBrowser() {
        isMakingDefault = true
        Task {
            await DefaultBrowser.makeLodge()
            isDefaultBrowser = DefaultBrowser.isLodge
            isMakingDefault = false
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

/// Lodge as the app macOS opens web links with (D6).
@MainActor
enum DefaultBrowser {
    private static let schemes = ["http", "https"]
    private static let logger = Logger(subsystem: "dev.lodge", category: "settings")

    /// Both http and https links open in an app with Lodge's bundle id.
    static var isLodge: Bool {
        schemes.allSatisfy { scheme in
            guard let probe = URL(string: "\(scheme)://"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
            else { return false }
            return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }
    }

    /// Asks macOS to open http and https links in this copy of Lodge; a scheme the user declines is logged and left.
    static func makeLodge() async {
        for scheme in schemes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            } catch {
                logger.error(
                    "Default browser not set for \(scheme, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
