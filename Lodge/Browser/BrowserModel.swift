import AppKit
import LodgeKit
import Observation
import WebKit

/// State and actions of one workspace: its saved links, its open tabs and their web views. Which tab a window shows,
/// and what acts on it, is the window's (`BrowserPane`, through the coordinator's `WindowSelections`).
@MainActor
@Observable
final class BrowserModel {
    let workspaceID: UUID
    /// Every tab of the workspace runs on this store; nil for Anonymous, whose tabs each get their own.
    let store: StoreRef?
    /// The Anonymous workspace: each tab is its own browser, its bookmarks keep their icons, nothing is recorded.
    var isAnonymous: Bool { workspaceID == Workspace.anonymousID }
    /// Every open tab. A tab keeps its web view, built when it is first selected, until it closes or the workspace
    /// is released (`releaseViews()`).
    private(set) var tabs = TabList() {
        didSet { didChangeSession() }
    }
    private(set) var library: LinkLibrary {
        didSet { didChangeSession() }
    }
    /// The sidebar's entries, each link paired with its open tab, rebuilt only when `tabs` or
    /// `library` change.
    private(set) var sidebar = SidebarSections()
    /// Load progress per tab, kept apart from `tabs` so progress ticks redraw only the progress line.
    private(set) var loadProgress: [TabID: Double] = [:]
    /// Each page's security, kept apart from `tabs` like progress; gone with the tab.
    private(set) var security: [TabID: SiteSecurity] = [:]
    /// Each tab's page zoom; absent means `PageZoom.actual`. Gone with the tab.
    private(set) var zoom: [TabID: Double] = [:]
    /// Each tab's decoded favicon, kept apart from `tabs` so an icon arriving redraws only its icon.
    private(set) var favicons: [TabID: NSImage] = [:]

    /// Shared by every workspace's model.
    @ObservationIgnored let registry: WebViewRegistry
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]
    /// Restored or released tabs whose web view is not built yet; the load that builds one is not a visit.
    @ObservationIgnored private var restoredTabs: Set<TabID> = []
    /// Decoded icons of Anonymous bookmarks, by link, with the bytes they were decoded from.
    @ObservationIgnored private var storedIcons: [UUID: (data: Data, image: NSImage)] = [:]
    /// Released tabs' `interactionState`, in memory only, put back when the view is rebuilt.
    @ObservationIgnored private var savedStates: [TabID: Any] = [:]
    /// Each popup tab's opener, so neither of a live pair is released while the other has a view.
    @ObservationIgnored private var popupOpeners: [TabID: TabID] = [:]
    /// Retries `releaseViews()` for tabs that were held; nil when no retry waits.
    @ObservationIgnored private var releaseRetryTask: Task<Void, Never>?
    @ObservationIgnored private var viewRelease = ViewRelease()
    /// How long a held tab waits before its release is tried again.
    static let releaseRetry: Duration = .seconds(30)
    /// Where this workspace's tabs record their visits, into its own history store; nil until that store opens,
    /// when the workspace keeps no history, and in layout renders. The store opens after the restored tab may have
    /// committed, so the recorder arrives knowing every tab's page as already seen, and a restored page's load
    /// finishing records nothing.
    @ObservationIgnored var historyRecorder: HistoryRecorder? {
        didSet {
            guard oldValue == nil, let historyRecorder else { return }
            for tab in tabs.tabs {
                if let url = tab.url { historyRecorder.send(.seen(tab: tab.id, url: url)) }
            }
        }
    }

    /// Runs the tabs' downloads; nil in layout renders, where a download does not run.
    @ObservationIgnored var downloads: DownloadManager?

    /// Default's pins, which every other workspace shows and changes in place of pins of its own; nil for Default and
    /// previews.
    @ObservationIgnored weak var sharedPins: (any SharedPins)?

    /// Which tabs the windows show, and where a new tab goes; nil for previews.
    @ObservationIgnored weak var placement: (any WindowPlacement)?

    /// The selected tab the session saved, the fallback for the first window (D8); nil when it was not one of the
    /// restored tabs.
    @ObservationIgnored private(set) var savedSelection: TabID?

    /// Called whenever the tabs or the library change in a way the session stores.
    @ObservationIgnored var onContentChange: (() -> Void)?
    /// The content last handed to `onContentChange`, so changes it does not store (loading, history
    /// buttons) do not call it.
    @ObservationIgnored private var lastContent: SessionSnapshot.WorkspaceContent?

    /// Starts from `content`, its tabs on `store`; without it, starts with `defaultLibrary`. Either way an empty
    /// workspace gets a blank tab. No tab has a web view until a window shows it (`view(for:)`).
    init(
        workspace: UUID = Workspace.defaultID, store: StoreRef? = .global,
        restoring content: SessionSnapshot.WorkspaceContent? = nil,
        registry: WebViewRegistry = WebViewRegistry(), defaultLibrary: LinkLibrary = LinkLibrary()
    ) {
        workspaceID = workspace
        self.store = store
        self.registry = registry
        if let content {
            let restored = content.restored(store: store)
            library = restored.library
            tabs = restored.tabs
            savedSelection = restored.selectedTab
            restoredTabs = Set(restored.tabs.tabs.map(\.id))
            for tab in restored.tabs.tabs { registry.attach(tab: tab.id, to: tab.store) }
        } else {
            library = defaultLibrary
        }
        refreshSidebar()
        if tabs.tabs.isEmpty { appendBlanks([TabID()]) }
        lastContent = storedContent
    }

    /// The store a new tab runs on: the workspace's own; in Anonymous a new browser of its own, except a WebKit popup,
    /// which shares its `opener`'s.
    func newTabStore(popupOf opener: TabID? = nil) -> StoreRef {
        if let opener, let shared = tabs[opener]?.store { return shared }
        return store ?? .ephemeral(UUID())
    }

    /// The tabs as the window resolver sees them: every open tab in sidebar order, and which are blank.
    var selectionTabs: WorkspaceTabs {
        WorkspaceTabs(
            workspace: workspaceID, order: sidebar.tabOrder,
            blank: Set(tabs.tabs.lazy.filter { $0.url == nil && !$0.isLoading }.map(\.id)))
    }

    // MARK: Showing and releasing

    /// The windows show this workspace; set by the coordinator.
    @ObservationIgnored var isShown = false

    /// The workspace is now on screen: a pending release retry stops. The coordinator then asks for each shown tab's
    /// view (`view(for:)`), which comes back from its saved interaction state when it was released.
    func didShow() {
        releaseRetryTask?.cancel()
        releaseRetryTask = nil
    }

    /// The workspace has left the screen: every tab's web view goes, its interaction state kept in memory, except a
    /// held tab's (`isHeld`), retried every `releaseRetry` and whenever a hold state changes. Stops once the
    /// workspace is shown again. Asked for while a pass runs, it makes that pass scan every tab again.
    func releaseViews() async {
        releaseRetryTask?.cancel()
        releaseRetryTask = nil
        guard !isShown, viewRelease.begin() else { return }
        var isAnyHeld: Bool
        repeat {
            isAnyHeld = false
            for id in tabs.tabs.map(\.id) {
                let held = registry.webView(for: id) != nil ? await isHeld(id) : false
                switch ViewRelease.step(isShown: isShown, hasView: registry.webView(for: id) != nil, isHeld: held) {
                case .stop:
                    viewRelease.stop()
                    return
                case .skip: continue
                case .hold: isAnyHeld = true
                case .release: release(id)
                }
            }
        } while viewRelease.finishScan()
        guard ViewRelease.needsRetry(isShown: isShown, isAnyHeld: isAnyHeld) else { return }
        releaseRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.releaseRetry)
            guard !Task.isCancelled, let self else { return }
            self.releaseRetryTask = nil
            await self.releaseViews()
        }
    }

    /// A tab's capture or fullscreen state changed: a held background workspace tries its release again now.
    func holdStateChanged(_ id: TabID) {
        guard !isShown, releaseRetryTask != nil else { return }
        Task { await releaseViews() }
    }

    /// The tab plays media, captures camera or microphone, is in fullscreen, or is one of a popup and its opener that
    /// both still have a view.
    private func isHeld(_ id: TabID) async -> Bool {
        guard let view = registry.webView(for: id) else { return false }
        if view.cameraCaptureState != .none || view.microphoneCaptureState != .none { return true }
        if view.fullscreenState != .notInFullscreen { return true }
        if let opener = popupOpeners[id], registry.webView(for: opener) != nil { return true }
        if popupOpeners.contains(where: { $0.value == id && registry.webView(for: $0.key) != nil }) { return true }
        return await view.requestMediaPlaybackState() == .playing
    }

    /// Destroys the tab's web view; the tab keeps its URL and title, and its page's interaction state waits in
    /// memory for the view to be rebuilt.
    private func release(_ id: TabID) {
        guard let tab = tabs[id], registry.webView(for: id) != nil else { return }
        controllers[id]?.didDeselect()
        controllers[id] = nil
        let state = registry.release(id)
        if tab.url != nil, let state { savedStates[id] = state }
        restoredTabs.insert(id)
        if loadProgress[id] != nil { loadProgress[id] = nil }
        update(id) {
            $0.isLive = false
            $0.isLoading = false
        }
    }

    /// What the session store keeps of the workspace, `selectedTab` being the coordinator's choice.
    func content(selectedTab: TabID?) -> SessionSnapshot.WorkspaceContent {
        SessionSnapshot.WorkspaceContent(tabs: tabs, library: library, selectedTab: selectedTab)
    }

    /// The stored content apart from the selection, which the coordinator saves itself.
    private var storedContent: SessionSnapshot.WorkspaceContent { content(selectedTab: nil) }

    private func didChangeSession() {
        refreshSidebar()
        let content = storedContent
        guard content != lastContent else { return }
        lastContent = content
        onContentChange?()
    }

    private func refreshSidebar() {
        let sections = SidebarSections(
            pins: pins, bookmarks: library.bookmarks, tabs: tabs, pinsAreShared: sharedPins != nil)
        if sections != sidebar { sidebar = sections }
    }

    /// The pins the sidebar shows: Default's when shared, else the library's own.
    var pins: [SavedLink] { sharedPins?.pins ?? library.links(on: .pins) }

    /// Default's pins changed, or were just shared with this workspace: the sidebar shows them.
    func sharedPinsDidChange() { refreshSidebar() }

    // MARK: Tabs

    /// Cmd-click on a link: the link opens in a new tab of this workspace (in Anonymous a new browser), shown in the
    /// window showing `source`.
    func open(url: URL, from source: TabID) {
        let tab = BrowserTab(store: newTabStore(), url: url)
        append(tab, load: true)
        placement?.didOpen(tab.id, in: workspaceID, from: source)
    }

    /// A tab moved or opened here from another workspace: a loose tab on this workspace's store (in Anonymous a new
    /// browser) with only the address and title, its web view built when a window shows it.
    func receive(url: URL, title: String) -> TabID {
        let tab = BrowserTab(store: newTabStore(), url: url, title: title, isLive: false)
        changeTabs { $0.open(tab) }
        return tab.id
    }

    /// Closes the tab with every popup it opened, directly or through them, and their web views. A link's row stays,
    /// not open. A window showing one of them moves on first (`WindowPlacement.willClose`); closing the last tab
    /// leaves a blank one.
    func close(_ id: TabID) {
        guard tabs[id] != nil else { return }
        let closing = closingSet(for: id)
        placement?.willClose(closing, of: self)
        remove(closing)
    }

    /// The tab and every popup it opened, directly or through them.
    func closingSet(for id: TabID) -> Set<TabID> {
        Set([id] + PopupTree.descendants(of: id, openers: popupOpeners))
    }

    /// Removes the tabs; when none is left, a blank one takes their place.
    func remove(_ ids: Set<TabID>) {
        guard ids.contains(where: { tabs[$0] != nil }) else { return }
        changeTabs { tabs in
            for id in ids { tabs.close(id) }
        }
        if tabs.tabs.isEmpty { appendBlanks([TabID()]) }
    }

    /// Appends blank tabs with these ids, without web views.
    func appendBlanks(_ ids: [TabID]) {
        guard !ids.isEmpty else { return }
        changeTabs { tabs in
            for id in ids { tabs.open(BrowserTab(id: id, store: newTabStore(), isLive: false)) }
        }
    }

    /// Called by WebKit for popups and `target=_blank`: the new tab runs on the configuration it hands over and is
    /// shown in the window showing `source`; WebKit loads it.
    func openPopup(from source: TabID, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard tabs[source] != nil else { return nil }
        let popup = BrowserTab(store: newTabStore(popupOf: source))
        popupOpeners[popup.id] = source
        let view = append(popup, configuration: configuration, load: false)
        placement?.didOpen(popup.id, in: workspaceID, from: source)
        return view
    }

    /// Appends `tab` and builds its web view, loading `tab.url` when `load` is true; which window shows it is the
    /// caller's.
    @discardableResult
    func append(_ tab: BrowserTab, configuration: WKWebViewConfiguration? = nil, load: Bool) -> LodgeWebView? {
        var tab = tab
        tab.isLive = false
        changeTabs { $0.open(tab) }
        return view(for: tab.id, configuration: configuration, load: load)
    }

    /// A window now shows `id` in place of `previous`: the previous tab's sheet ends and it stops taking focus when
    /// shown, unless another window still shows it; the folders above the new tab's bookmark open, and it gets its
    /// web view.
    func didSelect(_ id: TabID?, previous: TabID?, previousStillShown: Bool) {
        if let previous, previous != id, !previousStillShown {
            controllers[previous]?.didDeselect()
            registry.webView(for: previous)?.focusesWhenShown = false
        }
        guard let id else { return }
        if let link = tabs[id]?.link { changeLibrary { $0.reveal(link) } }
        view(for: id)
    }

    /// The tab's web view, building it (registry + TabController) when the tab has none, then marking the tab
    /// live. Loads `tab.url` when it built the view and `load` is true. Nil for an unknown tab.
    /// The ONLY place that sets `isLive = true`.
    @discardableResult
    func view(for id: TabID, configuration: WKWebViewConfiguration? = nil, load: Bool = true) -> LodgeWebView? {
        guard let tab = tabs[id] else { return nil }
        if let view = registry.webView(for: id) { return view }
        let isRestoring = restoredTabs.remove(id) != nil
        let saved = savedStates.removeValue(forKey: id)
        let view = registry.make(
            for: id, store: tab.store, configuration: configuration, zoom: zoom[id] ?? PageZoom.actual)
        update(id) { $0.isLive = true }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        let controller = TabController(
            tab: id, webView: view, model: self, faviconSession: registry.faviconSession(for: tab.store))
        controllers[id] = controller
        if load, let saved {
            controller.browserWillLoad()
            controller.expectsRestoreCommit = true
            view.interactionState = saved
        } else if load, let url = tab.url {
            controller.browserWillLoad()
            let navigation = view.load(URLRequest(url: url))
            if isRestoring { controller.restoreNavigation = navigation }
        }
        return view
    }

    /// Every change to `tabs` goes through here: a tab that closes loses everything kept for it. A new tab holds its
    /// store; a closed one lets go of it, and its web view goes, on the next main-actor turn, so a WebKit callback
    /// running on it (a popup's opener) returns first.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let before = tabs.tabs.map(\.id)
        change(&tabs)
        let kept = Set(before)
        for tab in tabs.tabs where !kept.contains(tab.id) { registry.attach(tab: tab.id, to: tab.store) }
        let dropped = before.filter { tabs[$0] == nil }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            controllers[id] = nil
            restoredTabs.remove(id)
            savedStates[id] = nil
            popupOpeners[id] = nil
            popupOpeners = popupOpeners.filter { $0.value != id }
            historyRecorder?.send(.closed(tab: id))
            if loadProgress[id] != nil { loadProgress[id] = nil }
            if favicons[id] != nil { favicons[id] = nil }
            if security[id] != nil { security[id] = nil }
            if zoom[id] != nil { zoom[id] = nil }
        }
        Task { @MainActor [registry] in
            registry.detach(tabs: dropped)
        }
    }

    /// Writes to `tabs` only when the tab really changes, so unchanged KVO ticks do not redraw the window.
    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let old = tabs[id] else { return }
        var tab = old
        change(&tab)
        if tab != old { tabs.update(id) { $0 = tab } }
    }

    /// Keeps the tab's icon; in Anonymous a bookmark's tab also stores it in the bookmark, for when it has no tab.
    func setFavicon(_ image: NSImage?, for id: TabID) {
        guard let tab = tabs[id], favicons[id] !== image else { return }
        favicons[id] = image
        if let image, let link = tab.link, isAnonymous, library.links(on: .bookmarks).contains(where: { $0.id == link }) {
            storeIcon(image, in: link)
        }
    }

    /// The row's icon: its open tab's favicon, else a shared pin's from Default, else the icon an Anonymous bookmark
    /// stored.
    func favicon(for item: SidebarItem) -> NSImage? {
        if let tab = item.tab, let image = favicons[tab.id] { return image }
        guard case .link(let link, let shelf, _) = item else { return nil }
        if shelf == .pins, let sharedPins { return sharedPins.pinFavicon(link.id) }
        guard let data = link.icon else { return nil }
        if let cached = storedIcons[link.id], cached.data == data { return cached.image }
        guard let cgImage = LinkIcon.image(from: data) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        storedIcons[link.id] = (data, image)
        return image
    }

    private func storeIcon(_ image: NSImage, in link: UUID) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = LinkIcon.png(from: cgImage)
        else { return }
        changeLibrary { $0.setIcon(link, data) }
    }

    func setProgress(_ progress: Double, for id: TabID) {
        if loadProgress[id] != progress { loadProgress[id] = progress }
    }

    func setSecurity(_ value: SiteSecurity, for id: TabID) {
        guard tabs[id] != nil, security[id] != value else { return }
        security[id] = value
    }

    // MARK: Links

    /// A fresh tab on the link, in this workspace.
    func tab(for link: SavedLink) -> BrowserTab {
        BrowserTab(store: newTabStore(), url: link.url, title: link.title, link: link.id)
    }

    /// Whether the tab has a page to save as a link.
    func canAddLink(from id: TabID) -> Bool { savablePage(of: id) != nil }

    private func savablePage(of id: TabID) -> (tab: BrowserTab, url: URL)? {
        guard let tab = tabs[id], let url = tab.url else { return nil }
        return (tab, url)
    }

    /// Saves the tab's page on `shelf`. A loose tab becomes that link's tab, so its row moves to the
    /// shelf and outlives closing it. A pin while pins are shared is a copy in Default, and the tab stays as it is.
    func addLink(_ shelf: LinkShelf, from id: TabID) {
        guard let page = savablePage(of: id) else { return }
        if shelf == .pins, let sharedPins {
            sharedPins.pin(from: page.tab)
            return
        }
        let link = library.add(page.url, title: page.tab.displayTitle, to: shelf)
        if isAnonymous, shelf == .bookmarks, let image = favicons[id] { storeIcon(image, in: link.id) }
        if page.tab.link == nil { update(id) { $0.link = link.id } }
    }

    /// Pins `url` on this workspace's own pins (Default's), or returns the pin already there for it.
    @discardableResult
    func addPin(_ url: URL, title: String) -> SavedLink {
        library.add(url, title: title, to: .pins)
    }

    /// Removes the pin, from Default when pins are shared; its open tab carries on as a loose tab.
    func unpin(_ id: UUID) {
        if let sharedPins { sharedPins.unpin(id) } else { removeLink(id) }
    }

    /// Pins a copy of the bookmark, in Default when pins are shared; the bookmark stays.
    func pin(bookmark link: SavedLink) {
        if let sharedPins { sharedPins.pin(from: link) } else { addPin(link.url, title: link.title) }
    }

    /// Drops the link's row, or a folder with every row in it; an open tab of a removed link carries on as a
    /// loose tab.
    func removeLink(_ id: UUID) {
        let removed = Set(library.remove(id))
        let loosened = tabs.tabs.filter { $0.link.map(removed.contains) == true }.map(\.id)
        guard !loosened.isEmpty else { return }
        changeTabs { tabs in
            for id in loosened { tabs.update(id) { $0.link = nil } }
        }
    }

    /// Writes the library only when `change` really changes it, so a no-op stores and redraws nothing.
    private func changeLibrary(_ change: (inout LinkLibrary) -> Void) {
        var changed = library
        change(&changed)
        if changed != library { library = changed }
    }

    // MARK: Bookmark folders

    /// Opens or closes the folder in the sidebar; the state is kept with the session.
    func setFolderExpanded(_ id: UUID, _ isExpanded: Bool) {
        changeLibrary { $0.setExpanded(id, isExpanded) }
    }

    /// Appends a folder named `title` (blank: "New Folder") to `parent`, the root for nil, opening `parent`
    /// so the folder shows. Returns the folder's id; nil for an unknown parent.
    @discardableResult
    func newFolder(in parent: UUID? = nil, title: String = "New Folder") -> UUID? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder: BookmarkFolder?
        changeLibrary { library in
            let parent = parent ?? library.bookmarks.id
            folder = library.addFolder(name.isEmpty ? "New Folder" : name, in: parent)
            if folder != nil { library.setExpanded(parent, true) }
        }
        return folder?.id
    }

    /// Retitles a folder or bookmark; a blank title changes nothing.
    func rename(_ id: UUID, to title: String) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        changeLibrary { $0.rename(id, to: name) }
    }

    /// Moves a bookmark or folder into `folder` at `index` (see `LinkLibrary.moveBookmark`); false when the
    /// move is refused.
    @discardableResult
    func moveBookmark(_ id: UUID, into folder: UUID, at index: Int?) -> Bool {
        guard library.canMoveBookmark(id, into: folder) else { return false }
        return library.moveBookmark(id, into: folder, at: index)
    }

    /// Moves the pin so it ends at `index` among the pins, Default's when shared.
    func movePin(_ id: UUID, to index: Int) {
        if let sharedPins { sharedPins.movePin(id, to: index) } else { library.move(id, to: index) }
    }

    // MARK: Import and export

    /// Whether `importBookmarks(from:)` is running, from its start until the folder is added or the import fails;
    /// a cancelled import counts until its read has ended.
    private(set) var isImportingBookmarks = false

    /// Reads the bookmark file at `url` off the main actor, then adds it to the root as one open folder named
    /// after the file. Throws `BookmarkFile.ReadError`, `NetscapeBookmarks.ImportError` or, when the calling task
    /// is cancelled, `CancellationError`, leaving the library as it was. Cancelling reaches the read, but a
    /// SwiftSoup parse under way runs to its end, and its folder is then dropped.
    func importBookmarks(from url: URL) async throws {
        isImportingBookmarks = true
        defer { isImportingBookmarks = false }
        let read = Task.detached(priority: .userInitiated) { try BookmarkFile.read(url) }
        let folder = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        try Task.checkCancellation()
        changeLibrary { library in
            library.insert(folder, in: library.bookmarks.id)
            library.setExpanded(folder.id, true)
        }
    }

    /// Writes every bookmark to `url` as one Netscape bookmark file in UTF-8, replacing it atomically.
    func exportBookmarks(to url: URL) throws {
        try Data(NetscapeBookmarks.export(library.bookmarks).utf8).write(to: url, options: .atomic)
    }

    // MARK: Navigation

    /// Loads `url` in the tab; false when the tab has no web view to load in.
    func load(_ url: URL, in id: TabID) -> Bool {
        guard let view = view(for: id, load: false) else { return false }
        update(id) { $0.url = url }
        controllers[id]?.browserWillLoad()
        view.load(URLRequest(url: url))
        return true
    }

    /// Reloads the tab; a restored tab whose view has no page yet loads its address.
    func reload(_ id: TabID) {
        guard let view = view(for: id, load: false) else { return }
        if view.url == nil, let url = tabs[id]?.url {
            controllers[id]?.browserWillLoad()
            view.load(URLRequest(url: url))
        } else {
            view.reload()
        }
    }

    /// Stores the tab's zoom (dropping the entry at actual size) and applies it to its web view.
    func setZoom(_ value: Double, for id: TabID) {
        zoom[id] = value == PageZoom.actual ? nil : value
        view(for: id, load: false)?.pageZoom = value
    }
}

/// Which tabs the browser windows show, and where a tab a page opened goes; the coordinator, set on every model.
@MainActor
protocol WindowPlacement: AnyObject {
    /// A window shows the tab.
    func isShown(_ tab: TabID) -> Bool
    /// The tab just opened in `workspace`: the window showing `source` shows it, else the last active one.
    func didOpen(_ tab: TabID, in workspace: UUID, from source: TabID?)
    /// The tabs are about to close in `model`: each window showing one moves on (D3).
    func willClose(_ tabs: Set<TabID>, of model: BrowserModel)
}
