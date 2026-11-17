import AppKit
import LodgeKit
import SwiftUI
import os

/// Settings, drawn in its tab's page card at `lodge://settings`. `DownloadSettingsModel` writes each change to
/// UserDefaults at once, and `DownloadManager` reads them at each download, so they apply to the next one; every
/// Settings tab shows the one app-wide model, so a change shows at once in each. Search picks Default's engine and
/// edits the engines added to Default, kept in the session with Default's content; they apply to the next search.
/// "Rest tabs after" is the coordinator's, for every workspace, and applies at once; below it, what a resting tab keeps
/// on this Mac (D5).
struct SettingsView: View {
    let coordinator: WorkspaceCoordinator
    @Environment(\.downloadSettings) private var injected
    /// Bumped after the folder panel closes, so the menu redraws even when the selection did not change.
    @State private var menuRevision = 0
    private let defaultBrowser = DefaultBrowserStatus.shared

    private static let appModel = DownloadSettingsModel()
    private var model: DownloadSettingsModel { injected ?? Self.appModel }

    private enum Option: Hashable {
        case folder(DownloadFolderChoice.Selection)
        case other
    }

    var body: some View {
        @Bindable var model = model
        // The page scrolls rather than the form, whose rows are then all laid out at once.
        ScrollView {
            Form {
                Section("General") {
                    LabeledContent("Default browser") {
                        if defaultBrowser.isLodge == true {
                            Label("Lodge is your default browser", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Make Lodge the Default Browser", action: defaultBrowser.makeLodge)
                                .disabled(defaultBrowser.isLodge == nil || defaultBrowser.isMaking)
                        }
                    }
                    Picker("Rest tabs after", selection: restAfter) {
                        ForEach(RestAfter.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    Text("A tab you have not looked at for this long gives back its memory, and reloads where you left it when selected. Tabs playing, recording or with unsent typing stay awake.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Resting tabs keep their place on this Mac: the address, scroll position and, for tabs that never sent a form, their back and forward history. Text in form fields and posted form data are never kept, and Anonymous keeps nothing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Search") {
                    Picker("Search with", selection: defaultEngine) {
                        ForEach(coordinator.searchCatalog(for: Workspace.defaultID).available) { engine in
                            Text(verbatim: engine.name).tag(engine.id)
                        }
                    }
                    Text("Default and the workspaces that follow it search with this engine. Anonymous uses its own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SearchEngineEditor(
                        coordinator: coordinator, workspace: Workspace.defaultID, isDrafting: .constant(false))
                    Text("Engines added here can be picked in every workspace, Anonymous included.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                Section("About") {
                    LabeledContent("Version", value: About.appVersion)
                    LabeledContent("macOS", value: About.systemVersion)
                    LabeledContent("Data folder") {
                        VStack(alignment: .trailing, spacing: 6) {
                            if let folder = About.dataFolder {
                                Text(folder.path(percentEncoded: false))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .multilineTextAlignment(.trailing)
                                    .help(folder.path(percentEncoded: false))
                            } else {
                                Text("Unavailable")
                            }
                            Button("Show in Finder", action: About.revealDataFolder)
                                .disabled(About.dataFolder == nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        // As the sidebar's: an always-shown scroller would draw an opaque track over the page.
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .onAppear(perform: defaultBrowser.refresh)
        // The user may have changed the default browser in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            defaultBrowser.refresh()
        }
    }

    /// The engine Default searches with now, so a choice that no longer resolves shows its fallback. The menu offers
    /// only engines Default can pick.
    private var defaultEngine: Binding<String> {
        Binding {
            coordinator.searchCatalog(for: Workspace.defaultID).engine.id
        } set: { id in
            try? coordinator.chooseSearchEngine(id, for: Workspace.defaultID)
        }
    }

    /// Every workspace's rest time, Anonymous included; a pick applies at once.
    private var restAfter: Binding<RestAfter> {
        Binding { coordinator.restAfter } set: { coordinator.restAfter = $0 }
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
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for downloads.")
        panel.directoryURL = model.folder
        // The panel's grant on the folder is held until Lodge quits, so the model can bookmark it afterwards.
        let chosen = panel.runModal() == .OK ? panel.url : nil
        Task {
            await model.useFolder(chosen)
            menuRevision += 1
        }
    }
}

extension RestAfter {
    fileprivate var title: String {
        switch self {
        case .five: String(localized: "5 minutes")
        case .fifteen: String(localized: "15 minutes")
        case .thirty: String(localized: "30 minutes")
        case .sixty: String(localized: "60 minutes")
        case .never: String(localized: "Never")
        }
    }
}

extension EnvironmentValues {
    /// The download settings a Settings tab shows; nil for the app-wide model over the standard defaults.
    @Entry var downloadSettings: DownloadSettingsModel?
}

/// What Settings' About section shows.
@MainActor
enum About {
    /// "1.2 (34)": the marketing version and the build.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    /// "26.1" or "26.1.2", the patch left out when it is 0.
    static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(os.majorVersion).\(os.minorVersion)"
        return os.patchVersion == 0 ? base : "\(base).\(os.patchVersion)"
    }

    /// The folder Lodge keeps its session, workspaces and history in; nil when Application Support cannot be found.
    static var dataFolder: URL? { try? SessionStore.appDirectory() }

    /// Selects the data folder in a Finder window, making it first if Lodge has saved nothing yet.
    static func revealDataFolder() {
        guard let folder = dataFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// Whether Lodge is the default browser, shared by every Settings tab so each shows the same answer.
@MainActor @Observable
final class DefaultBrowserStatus {
    static let shared = DefaultBrowserStatus()

    /// Whether Lodge opens http and https links; nil until first read.
    private(set) var isLodge: Bool?
    private(set) var isMaking = false

    func refresh() { isLodge = DefaultBrowser.isLodge }

    /// macOS asks the user to confirm each scheme; the status is read again whatever they chose.
    func makeLodge() {
        isMaking = true
        Task {
            await DefaultBrowser.makeLodge()
            refresh()
            isMaking = false
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
