import Foundation
import LodgeKit
import Observation
import WebKit

/// Owns the workspaces, one `BrowserModel` per workspace (built when first needed, until then its saved content
/// waits dormant), the window and which workspace it shows, the shared web view registry, and the session they are
/// saved to.
@MainActor
@Observable
final class WorkspaceCoordinator {
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

    /// The History window's model; its visits are Default's and open in Default.
    @ObservationIgnored private(set) lazy var history = HistoryModel { [unowned self] url in
        switchTo(Workspace.defaultID)
        model(for: Workspace.defaultID)?.open(historyURL: url)
    }

    /// Where Default's tabs record their visits; nil until the history store opens.
    @ObservationIgnored var defaultHistoryRecorder: HistoryRecorder? {
        didSet { models[Workspace.defaultID]?.historyRecorder = defaultHistoryRecorder }
    }

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
        if workspace.id == Workspace.defaultID { model.historyRecorder = defaultHistoryRecorder }
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
