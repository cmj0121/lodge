import Foundation
import LodgeKit
import Observation
import os
import WebKit

/// Owns the workspaces, one `BrowserModel` per workspace (built when first needed, until then its saved content
/// waits dormant), the window and which workspace it shows, the shared web view registry, and the session they are
/// saved to.
@MainActor
@Observable
final class WorkspaceCoordinator: WorkspaceDeletionSteps {
    private(set) var workspaces: WorkspaceList
    let window: WindowState
    /// The window menus and keys act in; the only one for now.
    var keyWindow: WindowState { window }

    @ObservationIgnored let registry: WebViewRegistry
    @ObservationIgnored private var models: [UUID: BrowserModel] = [:]
    @ObservationIgnored private var dormant: [UUID: SessionSnapshot.WorkspaceContent]
    @ObservationIgnored private(set) var pendingDeletions: [UUID]
    @ObservationIgnored private let session: SessionStore?
    @ObservationIgnored private let appDirectory: URL?
    @ObservationIgnored private let downloads: DownloadManager?
    @ObservationIgnored private let defaultLibrary: LinkLibrary

    /// The History window's model: it shows the key window's workspace's visits, and a visit opens there.
    @ObservationIgnored private(set) lazy var history = HistoryModel { [unowned self] url in
        active.open(historyURL: url)
    }

    /// Each workspace's open history file; a workspace is missing while its file opens, when it could not open,
    /// and when it keeps no history.
    @ObservationIgnored private(set) var historyStores: [UUID: HistoryStore] = [:]
    @ObservationIgnored private var historyOpenings: [UUID: Task<Void, Never>] = [:]
    /// The workspaces whose history file could not open this run.
    @ObservationIgnored private var historyFailures: Set<UUID> = []

    /// The store of each workspace being deleted this run, kept once it has left the list.
    @ObservationIgnored private var deletingStores: [UUID: StoreRef] = [:]
    /// The history recorder of a workspace being deleted, from when its model goes until its file closes.
    @ObservationIgnored private var deletingRecorders: [UUID: HistoryRecorder] = [:]

    /// Starts from `snapshot` (nil: Default alone, with `defaultLibrary`), showing its window's workspace.
    init(
        restoring snapshot: SessionSnapshot?, session: SessionStore?, appDirectory: URL?,
        downloads: DownloadManager?, registry: WebViewRegistry = WebViewRegistry(),
        defaultLibrary: LinkLibrary = LinkLibrary()
    ) {
        let list = snapshot?.workspaceList ?? WorkspaceList()
        workspaces = list
        window = WindowState(activeWorkspace: list.resolve(snapshot?.windows.first?.activeWorkspace))
        dormant = Dictionary(
            (snapshot?.workspaces ?? []).map { ($0.workspace.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        pendingDeletions = snapshot?.pendingDeletions ?? []
        self.session = session
        self.appDirectory = appDirectory
        self.downloads = downloads
        self.registry = registry
        self.defaultLibrary = defaultLibrary
        downloads?.dataStore = { [weak self] in self?.dataStore(for: $0) }
        active.didShow(in: window)
    }

    /// The data store of a listed workspace's store, for a download's Retry; nil once the workspace is gone.
    func dataStore(for store: StoreRef) -> WKWebsiteDataStore? {
        guard workspaces.workspaces.contains(where: { $0.store == store }) else { return nil }
        return registry.dataStore(for: store)
    }

    var activeWorkspace: Workspace { workspaces[window.activeWorkspace] ?? workspaces.default }

    /// The shown workspace's model: what menus, the key monitor and the History window act on.
    var active: BrowserModel { model(of: activeWorkspace) }

    /// The workspace's model, built from its dormant content when first asked for; nil for an unknown workspace.
    func model(for id: UUID) -> BrowserModel? {
        workspaces[id].map(model(of:))
    }

    private func model(of workspace: Workspace) -> BrowserModel {
        if let model = models[workspace.id] { return model }
        let model = BrowserModel(
            workspace: workspace.id, store: workspace.store, restoring: dormant.removeValue(forKey: workspace.id),
            registry: registry, window: window,
            defaultLibrary: workspace.id == Workspace.defaultID ? defaultLibrary : LinkLibrary())
        model.downloads = downloads
        if let store = historyStores[workspace.id] { model.historyRecorder = HistoryRecorder(store: store) }
        model.onContentChange = { [weak self] _ in self?.didChange() }
        models[workspace.id] = model
        return model
    }

    /// What the session store keeps: the workspaces in bar order with each one's content, the window's workspace and
    /// the deletions still under way.
    var snapshot: SessionSnapshot {
        SessionSnapshot(
            workspaces: workspaces.workspaces.map { workspace in
                SessionSnapshot.WorkspaceSnapshot(
                    workspace: workspace, content: models[workspace.id]?.content ?? dormant[workspace.id] ?? .empty)
            },
            windows: [SessionSnapshot.WindowSnapshot(activeWorkspace: window.activeWorkspace)],
            pendingDeletions: pendingDeletions)
    }

    /// Saves the session once changes settle.
    private func didChange() {
        session?.schedule(snapshot)
    }

    // MARK: Switching

    /// Shows the workspace in the window: the window's find, prompt and overlay close, the workspace's selected tab
    /// comes back, and the one it replaces gives up its web views. An unknown or already shown workspace changes
    /// nothing.
    func switchTo(_ id: UUID) {
        guard let target = workspaces[id], target.id != window.activeWorkspace else { return }
        let old = active
        window.closeTransientSurfaces()
        window.activeWorkspace = target.id
        model(of: target).didShow(in: window)
        showActiveHistory()
        Task { await old.releaseViews() }
        didChange()
    }

    /// ⌘1–⌘9: 1 is Default, 2…9 the next workspaces in order; an empty slot does nothing.
    func switchTo(slot: Int) {
        if let workspace = workspaces.workspace(forSlot: slot) { switchTo(workspace.id) }
    }

    // MARK: Editing

    /// Adds an empty workspace at the end of the bar and switches to it.
    @discardableResult
    func create(name: String, symbol: String) throws(WorkspaceList.EditError) -> Workspace {
        let workspace = try workspaces.create(name: name, symbol: symbol)
        Task { await openHistoryStore(for: workspace.id) }
        switchTo(workspace.id)
        return workspace
    }

    func rename(_ id: UUID, to name: String) throws(WorkspaceList.EditError) {
        try workspaces.rename(id, to: name)
        didChange()
    }

    func setSymbol(_ id: UUID, _ symbol: String) throws(WorkspaceList.EditError) {
        try workspaces.setSymbol(id, symbol)
        didChange()
    }

    /// Moves a workspace in the bar; Default stays first.
    @discardableResult
    func move(from source: Int, to destination: Int) -> Bool {
        guard workspaces.move(from: source, to: destination) else { return false }
        didChange()
        return true
    }
}

// MARK: History

extension WorkspaceCoordinator {
    private static let historyLogger = Logger(subsystem: "dev.lodge", category: "history")

    /// Launch: opens every listed workspace's history file off the main actor, all at once; each one's tabs record
    /// into it once it has opened, and the History window shows the active one's as soon as it is there.
    func openHistoryStores() async {
        let openings = workspaces.workspaces.compactMap(openHistory(of:))
        showActiveHistory()
        for opening in openings { await opening.value }
    }

    /// Opens a new workspace's history file; a switch to it meanwhile shows the History window loading.
    func openHistoryStore(for id: UUID) async {
        guard let workspace = workspaces[id] else { return }
        let opening = openHistory(of: workspace)
        if id == window.activeWorkspace { showActiveHistory() }
        await opening?.value
    }

    /// Stops the workspace's recording, waits for what it already sent to be written, then closes its file; one
    /// still opening is waited for first.
    func closeHistory(of id: UUID) async throws {
        await historyOpenings[id]?.value
        historyFailures.remove(id)
        let recorder = models[id]?.historyRecorder ?? deletingRecorders.removeValue(forKey: id)
        models[id]?.historyRecorder = nil
        await recorder?.drain()
        guard let store = historyStores.removeValue(forKey: id) else { return }
        // The History window stops observing it first, or closing fails.
        if id == window.activeWorkspace { history.show(nil, state: .unavailable) }
        await history.stoppedFollowing()
        try store.close()
    }

    /// Quit: closes every history file; events still queued are dropped.
    func closeAllHistory() {
        for (id, store) in historyStores {
            models[id]?.historyRecorder = nil
            do {
                try store.close()
            } catch {
                Self.historyLogger.error("Could not close history: \(error.localizedDescription, privacy: .public)")
            }
        }
        historyStores = [:]
    }

    /// Starts opening the workspace's history file, or returns the opening under way; nil when it is open already,
    /// keeps no history, or cannot open because Application Support cannot be found.
    private func openHistory(of workspace: Workspace) -> Task<Void, Never>? {
        let id = workspace.id
        guard historyStores[id] == nil else { return nil }
        if let opening = historyOpenings[id] { return opening }
        guard workspace.kind != .anonymous else { return nil }
        guard let directory = appDirectory.flatMap({ WorkspaceFiles.historyDirectory(for: workspace, in: $0) }) else {
            Self.historyLogger.error("History is unavailable: Application Support cannot be found")
            historyFailures.insert(id)
            return nil
        }
        historyFailures.remove(id)
        let opening = Task {
            let opened = await Task.detached(priority: .userInitiated) {
                Result { try HistoryStore.open(directory: directory) }
            }.value
            didOpenHistory(id, opened)
        }
        historyOpenings[id] = opening
        return opening
    }

    /// Hands an opened file to its workspace's model, or closes it again when the workspace was deleted meanwhile.
    private func didOpenHistory(_ id: UUID, _ opened: Result<HistoryStore, any Error>) {
        historyOpenings[id] = nil
        switch opened {
        case .success(let store):
            guard workspaces[id] != nil else {
                try? store.close()
                return
            }
            historyStores[id] = store
            models[id]?.historyRecorder = HistoryRecorder(store: store)
        case .failure(let error):
            Self.historyLogger.error("History is unavailable: \(error.localizedDescription, privacy: .public)")
            historyFailures.insert(id)
        }
        if id == window.activeWorkspace { showActiveHistory() }
    }

    /// Shows the active workspace's history in the History window: loading while its file opens.
    private func showActiveHistory() {
        let workspace = activeWorkspace
        if let store = historyStores[workspace.id] {
            history.show(store, state: .ready)
        } else if workspace.kind == .anonymous {
            history.show(nil, state: .notKept)
        } else {
            history.show(nil, state: historyFailures.contains(workspace.id) ? .unavailable : .loading)
        }
    }
}

// MARK: Deleting

extension WorkspaceCoordinator {
    private static let deletionLogger = Logger(subsystem: "dev.lodge", category: "workspaces")

    /// Deletes a custom workspace with its tabs, bookmarks, history, sign-ins and site data; a window showing it
    /// goes to Default. A deletion that fails stays pending and is finished at the next launch. Default is refused.
    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        guard let workspace = workspaces[id], workspace.kind != .default else { return false }
        let done = await WorkspaceDeletion.run(id, steps: self)
        if !done {
            Self.deletionLogger.error(
                "Workspace \(id.uuidString, privacy: .public) was not fully deleted; it is retried at next launch")
        }
        return done
    }

    /// Launch, before any history file opens: finishes the deletions the last run left pending.
    func retryPendingDeletions() async {
        let pending = pendingDeletions
        guard !pending.isEmpty else { return }
        await WorkspaceDeletion.retry(pending, steps: self)
        for id in pending where pendingDeletions.contains(id) {
            Self.deletionLogger.error(
                "Workspace \(id.uuidString, privacy: .public) is still not fully deleted; it is retried at next launch")
        }
    }

    private func deletingStore(of id: UUID) -> StoreRef { deletingStores[id] ?? .workspace(id) }

    func removeFromList(_ id: UUID) {
        guard let workspace = workspaces[id] else { return }
        if window.activeWorkspace == id { switchTo(Workspace.defaultID) }
        deletingStores[id] = workspace.store
        _ = try? workspaces.remove(id)
        if !pendingDeletions.contains(id) { pendingDeletions.append(id) }
    }

    func saveNow() {
        session?.writeNow(snapshot)
    }

    func destroyViews(of id: UUID) {
        dormant[id] = nil
        guard let model = models.removeValue(forKey: id) else { return }
        model.onContentChange = nil
        if let recorder = model.historyRecorder { deletingRecorders[id] = recorder }
        model.historyRecorder = nil
        registry.destroyAll(on: model.store)
    }

    func cancelDownloads(of id: UUID) {
        downloads?.cancel(store: deletingStore(of: id))
    }

    func forgetStore(of id: UUID) {
        registry.forget(store: deletingStore(of: id))
    }

    func removeWebsiteData(of id: UUID) async throws {
        guard case .workspace = deletingStore(of: id) else { return }
        try await WebViewRegistry.removeWebsiteData(for: id)
    }

    /// Deletes `Workspaces/<uuid>/`; without Application Support nothing of it was ever written.
    func removeFiles(of id: UUID) throws {
        guard let appDirectory else { return }
        try WorkspaceFiles.remove(id, in: appDirectory)
    }

    func clearPending(_ id: UUID) {
        pendingDeletions.removeAll { $0 == id }
        deletingStores[id] = nil
        deletingRecorders[id] = nil
    }
}
