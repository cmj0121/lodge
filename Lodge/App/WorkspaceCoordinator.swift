import AppKit
import Foundation
import LodgeKit
import Observation
import os
import WebKit

/// Owns the workspaces, one `BrowserModel` per workspace (built when first needed, until then its saved content
/// waits dormant), the browser windows and the tab each shows (`WindowSelections`: every window is on the active
/// workspace), the shared web view registry, and the session they are saved to.
@MainActor
@Observable
final class WorkspaceCoordinator: WorkspaceDeletionSteps {
    private(set) var workspaces: WorkspaceList
    /// Which tab each browser window shows, and the active workspace.
    private(set) var selections: WindowSelections
    var activeWorkspaceID: UUID { selections.active }
    /// The browser windows, key first, in `selections.windows` order.
    private(set) var windows: [WindowState]
    /// The browser window that is key; nil while History, Settings or a panel is.
    private(set) var keyBrowserWindow: WindowState?
    /// The browser window last key; History or Settings becoming key does not change it.
    private(set) var lastActiveBrowserWindow: WindowState?
    /// The pane menus act in; nil (items disabled) with no browser window.
    var commandPane: BrowserPane? { lastActiveBrowserWindow.map(pane(for:)) }
    /// The pane the key monitor acts in, only while a browser window is key.
    var keyPane: BrowserPane? { keyBrowserWindow.map(pane(for:)) }
    @ObservationIgnored private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    @ObservationIgnored private var keyObserver: (any NSObjectProtocol)?
    /// Opens a browser window scene for the id; installed from `BrowserCommands`' `openWindow`. Installing it opens,
    /// on the next main turn (it is installed during a view update), the windows asked for before it was there.
    @ObservationIgnored var windowOpener: ((WindowID) -> Void)? {
        didSet { DispatchQueue.main.async { [weak self] in self?.openPendingWindows() } }
    }
    /// Windows were asked for (launch's restored ones, ⌘N or a Dock click) before `windowOpener` was installed.
    @ObservationIgnored private var windowsPending = false
    /// Quitting: windows closing now stay in the session.
    @ObservationIgnored private var isQuitting = false
    #if DEBUG
        /// Layout self-checks: stands in for bringing a window forward, so a check never activates the app.
        @ObservationIgnored var bringForwardHook: ((WindowState) -> Void)?
    #endif

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
        commandPane?.open(historyURL: url)
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

    /// Starts from `snapshot` (nil: Default alone, with `defaultLibrary`) with its windows, each on its saved tab and
    /// waiting for its saved frame, all showing the first window's workspace; `openRestoredWindows` puts them on
    /// screen.
    init(
        restoring snapshot: SessionSnapshot?, session: SessionStore?, appDirectory: URL?,
        downloads: DownloadManager?, registry: WebViewRegistry = WebViewRegistry(),
        defaultLibrary: LinkLibrary = LinkLibrary()
    ) {
        let list = snapshot?.workspaceList ?? WorkspaceList()
        workspaces = list
        selections = WindowSelections(active: list.resolve(snapshot?.windows.first?.activeWorkspace))
        let saved = snapshot?.windows ?? []
        let restoredWindows = (saved.isEmpty ? [.init(activeWorkspace: list.default.id)] : saved)
            .map { window in
                let state = WindowState()
                state.pendingFrame = window.frame
                return (state: state, selectedTab: window.selectedTab)
            }
        let states = restoredWindows.map(\.state)
        windows = states
        lastActiveBrowserWindow = states.first
        dormant = Dictionary(
            (snapshot?.workspaces ?? []).map { ($0.workspace.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        pendingDeletions = snapshot?.pendingDeletions ?? []
        self.session = session
        self.appDirectory = appDirectory
        self.downloads = downloads
        self.registry = registry
        self.defaultLibrary = defaultLibrary
        downloads?.dataStore = { [weak self] in self?.dataStore(for: $0) }
        downloads?.storeHold = { [registry] id, store in
            if let store { registry.hold(download: id, on: store) } else { registry.releaseHold(download: id) }
        }
        registry.storeDropped = { [weak downloads] store in downloads?.forget(store: store) }
        let model = active
        let tabs = model.selectionTabs
        var restored = selections
        let change = restored.restore(
            restoredWindows.map { ($0.state.id, $0.selectedTab) }, fallback: model.savedSelection, in: tabs)
        model.appendBlanks(change.create)
        selections = restored
        show(model)
    }

    /// The data store a download's Retry runs on: a listed workspace's, nil once the workspace is gone; an anonymous
    /// tab's only while its tab or a download still holds it.
    func dataStore(for store: StoreRef) -> WKWebsiteDataStore? {
        if case .ephemeral = store { return registry.isHeld(store) ? registry.existingDataStore(for: store) : nil }
        guard workspaces.workspaces.contains(where: { $0.store == store }) else { return nil }
        return registry.dataStore(for: store)
    }

    var activeWorkspace: Workspace { workspaces[activeWorkspaceID] ?? workspaces.default }

    /// The active workspace's model, which every browser window shows.
    var active: BrowserModel { model(of: activeWorkspace) }

    /// The window's view of the active workspace.
    func pane(for window: WindowState) -> BrowserPane {
        BrowserPane(model: active, window: window, coordinator: self)
    }

    /// The workspace's model, built from its dormant content when first asked for; nil for an unknown workspace.
    func model(for id: UUID) -> BrowserModel? {
        workspaces[id].map(model(of:))
    }

    private func model(of workspace: Workspace) -> BrowserModel {
        if let model = models[workspace.id] { return model }
        let model = BrowserModel(
            workspace: workspace.id, store: workspace.store, restoring: dormant.removeValue(forKey: workspace.id),
            registry: registry,
            defaultLibrary: workspace.id == Workspace.defaultID ? defaultLibrary : LinkLibrary())
        model.downloads = downloads
        model.placement = self
        if let store = historyStores[workspace.id] { model.historyRecorder = HistoryRecorder(store: store) }
        models[workspace.id] = model
        if workspace.id == Workspace.defaultID {
            model.onContentChange = { [weak self] in
                self?.didChange()
                self?.pinsDidChange()
            }
        } else {
            model.onContentChange = { [weak self] in self?.didChange() }
            model.sharedPins = self
            model.sharedPinsDidChange()
        }
        return model
    }

    /// What the session store keeps: the workspaces in bar order with each one's content, the windows (key first)
    /// with the tab each shows and its frame, and the deletions still under way. A built workspace's selected tab is
    /// the first window's (key first) remembering one there, else the one it was restored with, while open (D8).
    var snapshot: SessionSnapshot {
        let active = activeWorkspaceID
        return SessionSnapshot(
            workspaces: workspaces.workspaces.map { workspace in
                let content = models[workspace.id].map { model in
                    let selected = (selections.remembered(in: workspace.id) ?? model.savedSelection)
                    return model.content(selectedTab: selected.flatMap { model.tabs[$0] != nil ? $0 : nil })
                }
                return SessionSnapshot.WorkspaceSnapshot(
                    workspace: workspace, content: content ?? dormant[workspace.id] ?? .empty)
            },
            windows: windows.isEmpty
                ? [SessionSnapshot.WindowSnapshot(activeWorkspace: active)]
                : windows.map { window in
                    SessionSnapshot.WindowSnapshot(
                        activeWorkspace: active, selectedTab: selections.shown(in: window.id),
                        frame: window.nsWindow.map { SessionSnapshot.WindowFrame($0.frame) } ?? window.pendingFrame)
                },
            pendingDeletions: pendingDeletions)
    }

    /// Saves the session once changes settle.
    private func didChange() {
        session?.schedule(snapshot)
    }

    // MARK: Switching

    /// Shows the workspace in every window: each window's find, prompt and overlay close, each window takes its tab
    /// there (D3), and the workspace it replaces gives up its web views. An unknown or already active workspace
    /// changes nothing.
    func switchTo(_ id: UUID) {
        guard let target = workspaces[id], target.id != activeWorkspaceID else { return }
        enter(target, closingBlanks: true)
    }

    /// Every window leaves the active workspace and takes a tab of `target`; the blanks the windows owned there
    /// close unless `closingBlanks` is false (the workspace is being deleted). A workspace no window has shown yet
    /// starts the key window on the tab it was restored with.
    private func enter(_ target: Workspace, closingBlanks: Bool) {
        let old = active
        for window in windows { window.closeTransientSurfaces() }
        let model = model(of: target)
        let leaving = old.selectionTabs
        let tabs = model.selectionTabs
        var next = selections
        if next.remembered(in: target.id) == nil, let saved = openSavedSelection(of: model), let key = next.windows.first {
            next.opened(saved, in: target.id, window: key.id)
        }
        let change = next.enter(tabs, leaving: leaving)
        model.appendBlanks(change.create)
        selections = next
        if closingBlanks { old.remove(Set(change.close)) }
        old.isShown = false
        show(model)
        showActiveHistory()
        Task { await old.releaseViews() }
        didChange()
    }

    /// The tab the workspace was restored with, while it is still open.
    private func openSavedSelection(of model: BrowserModel) -> TabID? {
        model.savedSelection.flatMap { model.tabs[$0] != nil ? $0 : nil }
    }

    /// For `open(tab:in:)`: the tab a window would take on switching to a workspace no window has shown yet (`enter`
    /// seeds the key window with the saved one, else D3 gives the first in sidebar order).
    private func entryTab(of model: BrowserModel) -> TabID? {
        openSavedSelection(of: model) ?? model.selectionTabs.order.first
    }

    /// The model is now on screen: each window's tab gets its web view.
    private func show(_ model: BrowserModel) {
        model.isShown = true
        model.didShow()
        for window in windows {
            if let tab = selections.shown(in: window.id) { model.view(for: tab) }
        }
    }

    /// ⌘1–⌘9: 1 is Default, 2…9 the next workspaces in order; an empty slot does nothing.
    func switchTo(slot: Int) {
        if let workspace = workspaces.workspace(forSlot: slot) { switchTo(workspace.id) }
    }

    // MARK: Editing

    /// Adds an empty workspace just before Anonymous and switches to it.
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

    /// Moves a custom workspace in the bar; Default stays first and Anonymous stays last.
    @discardableResult
    func move(from source: Int, to destination: Int) -> Bool {
        guard workspaces.move(from: source, to: destination) else { return false }
        didChange()
        return true
    }
}

// MARK: Windows and selection

extension WorkspaceCoordinator: WindowPlacement {
    func window(for id: WindowID) -> WindowState? {
        windows.first { $0.id == id }
    }

    func window(for nsWindow: NSWindow?) -> WindowState? {
        guard let nsWindow else { return nil }
        return windows.first { $0.nsWindow === nsWindow }
    }

    /// The window for a scene SwiftUI opened with this id: the registry's, else (it should not happen) a new window
    /// adopted as ⌘N would make it.
    func windowState(for id: WindowID) -> WindowState {
        window(for: id) ?? addWindow()
    }

    /// Launch: puts every restored window on screen, the first (the key window at quit) last so it ends up in front;
    /// waits for `windowOpener` when it is not installed yet.
    func openRestoredWindows() {
        windowsPending = true
        openPendingWindows()
    }

    /// Opens every window not on screen yet, once `windowOpener` is there.
    private func openPendingWindows() {
        guard windowsPending, let windowOpener else { return }
        windowsPending = false
        for window in windows.reversed() where window.nsWindow == nil { windowOpener(window.id) }
    }

    /// ⌘N and a Dock click with no window (D1, D5): a new window in front, on a new blank tab of the active workspace
    /// with the location prompt open; opened once `windowOpener` is installed when it is not yet.
    func newWindow() {
        let window = addWindow()
        guard let windowOpener else {
            windowsPending = true
            return
        }
        windowOpener(window.id)
    }

    @discardableResult
    private func addWindow() -> WindowState {
        let window = WindowState()
        window.locationPrompt = .newTab
        let model = active
        var next = selections
        let change = next.addWindow(window.id)
        model.appendBlanks(change.create)
        selections = next
        windows.insert(window, at: 0)
        lastActiveBrowserWindow = window
        if let tab = selections.shown(in: window.id) { model.view(for: tab) }
        didChange()
        return window
    }

    /// Brings the window to the front, key, with the app active.
    func bringForward(_ window: WindowState) {
        #if DEBUG
            if let bringForwardHook { return bringForwardHook(window) }
        #endif
        window.nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Brings every browser window forward, the key-first order kept, the first one key.
    func bringAllForward() {
        for window in windows.dropFirst().reversed() { window.nsWindow?.orderFront(nil) }
        windows.first?.nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The app is quitting: the windows that close from here on stay in the session.
    func prepareForQuit() {
        isQuitting = true
    }

    /// The window is on screen in `nsWindow`: it takes its saved frame (on the next main turn, after SwiftUI's first
    /// sizing), from now on it becoming key makes it the key browser window (and the first in `selections`), any other
    /// window becoming key leaves no key browser window, moving or resizing it saves the session, and closing it
    /// removes it (its tabs stay).
    func register(_ window: WindowState, nsWindow: NSWindow) {
        guard window.nsWindow !== nsWindow, windows.contains(where: { $0 === window }) else { return }
        if let old = window.nsWindow { stopObserving(ObjectIdentifier(old)) }
        window.nsWindow = nsWindow
        if let frame = window.pendingFrame {
            window.pendingFrame = nil
            DispatchQueue.main.async { [weak nsWindow] in
                let screens = NSScreen.screens.map { SessionSnapshot.WindowFrame($0.visibleFrame) }
                guard let nsWindow, let clamped = frame.clamped(to: screens) else { return }
                nsWindow.setFrame(clamped.rect, display: true)
            }
        }
        let center = NotificationCenter.default
        let save: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.didChange() }
        }
        windowObservers[ObjectIdentifier(nsWindow)] = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nsWindow, queue: .main) {
                [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let self, self.keyBrowserWindow === window { self.keyBrowserWindow = nil }
                }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: nsWindow, queue: .main, using: save),
            // Zoom, tiling and full screen resize without a live resize.
            center.addObserver(forName: NSWindow.didResizeNotification, object: nsWindow, queue: .main) {
                [weak self, weak nsWindow] _ in
                MainActor.assumeIsolated {
                    if let nsWindow, !nsWindow.inLiveResize { self?.didChange() }
                }
            },
            center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: nsWindow, queue: .main, using: save),
            center.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main) {
                [weak self, weak window, weak nsWindow] _ in
                MainActor.assumeIsolated {
                    guard let self, let nsWindow else { return }
                    self.stopObserving(ObjectIdentifier(nsWindow))
                    guard let window, window.nsWindow === nsWindow else { return }
                    self.didClose(window)
                }
            },
        ]
        if keyObserver == nil {
            keyObserver = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
                [weak self] notification in
                let key = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated { self?.didBecomeKey(key) }
            }
        }
        if nsWindow.isKeyWindow { didBecomeKey(ObjectIdentifier(nsWindow)) }
    }

    /// D5: the window leaves the registry and its remembered tabs; a blank it made and still owns closes, every
    /// other tab stays. While quitting it stays, so the session keeps it.
    private func didClose(_ window: WindowState) {
        if keyBrowserWindow === window { keyBrowserWindow = nil }
        guard !isQuitting else { return }
        window.nsWindow = nil
        let model = active
        let change = selections.removeWindow(window.id, in: model.selectionTabs)
        windows.removeAll { $0 === window }
        if lastActiveBrowserWindow === window { lastActiveBrowserWindow = windows.first }
        model.remove(Set(change.close))
        didChange()
    }

    private func stopObserving(_ nsWindow: ObjectIdentifier) {
        for observer in windowObservers.removeValue(forKey: nsWindow) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func didBecomeKey(_ key: ObjectIdentifier?) {
        guard let key, let window = windows.first(where: { $0.nsWindow.map(ObjectIdentifier.init) == key }) else {
            keyBrowserWindow = nil
            return
        }
        keyBrowserWindow = window
        lastActiveBrowserWindow = window
        selections.makeKey(window.id)
        if let index = windows.firstIndex(where: { $0 === window }), index != 0 {
            windows.insert(windows.remove(at: index), at: 0)
        }
    }

    /// Shows the tab in the window (D4); another window showing it is left as it is, and so is this window.
    func select(_ tab: TabID, in window: WindowState) -> SelectOutcome {
        let tabs = active.selectionTabs
        var outcome = SelectOutcome.unknown
        updateSelections {
            outcome = $0.select(tab, in: window.id, of: tabs)
            return SelectionChange()
        }
        return outcome
    }

    /// The tab just opened in `model` for `window`, which shows it when `model` is the active workspace's and
    /// remembers it there otherwise.
    func opened(_ tab: TabID, in model: BrowserModel, window: WindowState) {
        opened(tab, in: model.workspaceID, window: window)
    }

    private func opened(_ tab: TabID, in workspace: UUID, window: WindowState) {
        guard workspace == activeWorkspaceID else {
            selections.opened(tab, in: workspace, window: window.id)
            didChange()
            return
        }
        updateSelections {
            $0.opened(tab, in: workspace, window: window.id)
            return SelectionChange()
        }
    }

    func isShown(_ tab: TabID) -> Bool { selections.shownTabs.contains(tab) }

    func didOpen(_ tab: TabID, in workspace: UUID, from source: TabID?) {
        let window = source.flatMap { selections.window(showing: $0) }.flatMap(window(for:)) ?? lastActiveBrowserWindow
        if let window { opened(tab, in: workspace, window: window) }
    }

    func willClose(_ tabs: Set<TabID>, of model: BrowserModel) {
        let order = model.selectionTabs
        guard model.workspaceID == activeWorkspaceID else {
            _ = selections.closing(tabs, in: order)
            return
        }
        updateSelections { $0.closing(tabs, in: order) }
    }

    /// Runs `change` on the active workspace's selections: the blanks it asks for are appended first, then every
    /// window whose tab changed hides find and shows its new tab, and the session is saved.
    @discardableResult
    private func updateSelections(_ change: (inout WindowSelections) -> SelectionChange) -> SelectionChange {
        let before = selections
        var next = before
        let result = change(&next)
        let model = active
        model.appendBlanks(result.create)
        selections = next
        guard selections != before else { return result }
        let shown = selections.shownTabs
        for window in windows {
            let previous = before.shown(in: window.id)
            let tab = selections.shown(in: window.id)
            guard tab != previous else { continue }
            window.dismissFind()
            model.didSelect(tab, previous: previous, previousStillShown: previous.map(shown.contains) == true)
        }
        didChange()
        return result
    }
}

// MARK: Moving tabs

extension WorkspaceCoordinator {
    /// Opens the tab's page in a new selected tab of `destination`, on that workspace's own sign-ins (in Anonymous a
    /// new browser); only the address and title go along. The tab stays, and the window stays where it is. False for
    /// a tab with no address, an unknown tab, or a destination that is the tab's own workspace or not listed.
    @discardableResult
    func open(tab id: TabID, in destination: UUID) -> Bool {
        guard let source = model(holding: id), let tab = source.tabs[id], let url = tab.url,
            destination != source.workspaceID, let target = model(for: destination)
        else { return false }
        guard let window = lastActiveBrowserWindow else {
            _ = target.receive(url: url, title: tab.title)
            return true
        }
        // The tab the window shows there, or would show on switching there, gives way to the page when blank, so no
        // empty New Tab row is left behind.
        let replaced =
            selections.windows.first { $0.id == window.id }?.remembered[destination]
            ?? (selections.remembered(in: destination) == nil ? entryTab(of: target) : nil)
        let received = target.receive(url: url, title: tab.title)
        opened(received, in: destination, window: window)
        if let replaced, let blank = target.tabs[replaced], blank.url == nil, !blank.isLoading {
            target.close(replaced)
        }
        return true
    }

    /// `open(tab:in:)`, then closes the tab with every popup it opened.
    @discardableResult
    func move(tab id: TabID, to destination: UUID) -> Bool {
        guard let source = model(holding: id), open(tab: id, in: destination) else { return false }
        source.close(id)
        return true
    }

    /// Where a tab of `source` can go: every other workspace in bar order, Anonymous last.
    func destinations(from source: UUID) -> [Workspace] {
        workspaces.workspaces.filter { $0.id != source }
    }

    /// The built model with the tab open; a tab only opens in a built one.
    private func model(holding tab: TabID) -> BrowserModel? {
        models.values.first { $0.tabs[tab] != nil }
    }
}

// MARK: Shared pins

/// Default's pins, shown and changed from every other workspace.
@MainActor
protocol SharedPins: AnyObject {
    /// Default's pins, its model built (without web views) when needed.
    var pins: [SavedLink] { get }
    /// The favicon of the pin's open tab in Default.
    func pinFavicon(_ pin: UUID) -> NSImage?
    /// Pins a copy of the tab's page in Default, deduped by URL; the tab and the window stay as they are.
    func pin(from tab: BrowserTab)
    /// Pins a copy of the bookmark in Default (a new link, no icon); the bookmark stays.
    func pin(from link: SavedLink)
    /// Removes the pin from Default; Default's tab of it becomes loose.
    func unpin(_ id: UUID)
    func movePin(_ id: UUID, to index: Int)
    /// Switches every window to Default and opens the pin in `window`, or shows its open tab there.
    func openPin(_ link: SavedLink, from window: WindowState)
}

extension WorkspaceCoordinator: SharedPins {
    private var defaultModel: BrowserModel { model(of: workspaces.default) }

    var pins: [SavedLink] { defaultModel.library.links(on: .pins) }

    func pinFavicon(_ pin: UUID) -> NSImage? {
        let model = defaultModel
        return model.tabs.tab(forLink: pin).flatMap { model.favicons[$0.id] }
    }

    func pin(from tab: BrowserTab) {
        guard let url = tab.url else { return }
        defaultModel.addPin(url, title: tab.displayTitle)
    }

    func pin(from link: SavedLink) {
        defaultModel.addPin(link.url, title: link.title)
    }

    func unpin(_ id: UUID) { defaultModel.unpin(id) }

    func movePin(_ id: UUID, to index: Int) { defaultModel.movePin(id, to: index) }

    func openPin(_ link: SavedLink, from window: WindowState) {
        guard windows.contains(where: { $0 === window }) else { return }
        switchTo(Workspace.defaultID)
        pane(for: window).openLink(link)
    }

    /// Default's content changed: every built model of another workspace shows its pins again.
    fileprivate func pinsDidChange() {
        for (id, model) in models where id != Workspace.defaultID { model.sharedPinsDidChange() }
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
        if id == activeWorkspaceID { showActiveHistory() }
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
        if id == activeWorkspaceID { history.show(nil, state: .unavailable) }
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
        if id == activeWorkspaceID { showActiveHistory() }
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
    /// goes to Default. A deletion that fails stays pending and is finished at the next launch. Default and Anonymous
    /// are refused.
    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        guard let workspace = workspaces[id], workspace.kind == .custom else { return false }
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
        // destroyViews closes its tabs.
        if activeWorkspaceID == id { enter(workspaces.default, closingBlanks: false) }
        selections.forget(workspace: id)
        if let store = workspace.store { deletingStores[id] = store }
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
        model.placement = nil
        if let recorder = model.historyRecorder { deletingRecorders[id] = recorder }
        model.historyRecorder = nil
        registry.detach(tabs: model.tabs.tabs.map(\.id))
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
