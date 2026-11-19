import AppKit
import LodgeKit
import Observation
import os
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
    /// Every open tab. A tab keeps its web view, built when it is first selected, until it closes, the workspace
    /// is released (`releaseViews()`) or it rests unseen (the coordinator's rest timer).
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
    /// Which fingerprint apis each tab's current page, in any frame, has read (D4); absent means none. Cleared when
    /// the main frame commits a new document, and gone with the tab or its view.
    private(set) var fingerprintReads: [TabID: Set<FingerprintAPI>] = [:]
    /// What each protection page tab was opened for from the indicator (D5), by that page's tab, in memory only, so
    /// absent after relaunch; gone with the page's tab, and when the page is reached any other way.
    private var protectionTargets: [TabID: ProtectionTarget] = [:]
    /// The plain-http page each tab's main frame was about to load when it was stopped for the warning (D8), shown in
    /// place of the page until Go Back, Continue or another main-frame load; gone with the tab or its view.
    private(set) var plainHTTPWarnings: [TabID: URL] = [:]
    /// Tabs whose warned load was a back/forward one, so Continue goes to that history entry rather than loading
    /// afresh.
    @ObservationIgnored private var plainHTTPBackForward: Set<TabID> = []
    /// Bumped on every exception change, so views reading exceptions, which live outside the model, redraw.
    private(set) var fingerprintExceptionsRevision = 0

    /// Shared by every workspace's model.
    @ObservationIgnored let registry: WebViewRegistry
    @ObservationIgnored private var controllers: [TabID: TabController] = [:]
    /// Restored or released tabs whose web view is not built yet; the load that builds one is not a visit.
    @ObservationIgnored private var restoredTabs: Set<TabID> = []
    /// Decoded icons of pins and bookmarks, by link, with the bytes they were decoded from.
    @ObservationIgnored private var storedIcons: [UUID: (data: Data, image: NSImage)] = [:]
    /// Where this workspace keeps its links' icons on disk (D2); nil for Anonymous, whose bookmarks keep theirs in
    /// memory (`SavedLink.icon`), in layout renders without one, and once the workspace is being deleted.
    @ObservationIgnored var icons: LinkIconCache?
    /// Released tabs' `interactionState`, in memory only, put back when the view is rebuilt.
    @ObservationIgnored private var savedStates: [TabID: Any] = [:]
    /// Where this workspace's resting tabs keep their place on disk (D5); nil for Anonymous, which keeps none, in
    /// layout renders, and once the workspace is being deleted.
    @ObservationIgnored var places: PlaceStore?
    /// Tabs whose view sent a form, in its page or a frame: their `interactionState` holds the sent body, so their
    /// place on disk is a record only. Kept while the tab rests in memory, since that state comes back with it; a view
    /// built afresh, or from a place on disk, starts clean.
    @ObservationIgnored private var sentForm: Set<TabID> = []
    /// Each live tab's main-frame scroll position, as its page reports it, for a record's place.
    @ObservationIgnored private var scrolls: [TabID: MainScroll] = [:]
    private static let placesLogger = Logger(subsystem: "dev.lodge", category: "places")
    /// Each popup tab's opener, so neither of a live pair is released while the other has a view.
    @ObservationIgnored private var popupOpeners: [TabID: TabID] = [:]
    /// Each tab's unsent work (typed text, a form POST in flight) as its page reports it; gone with the tab or its view.
    @ObservationIgnored private var work: [TabID: PageWork] = [:]
    /// Whether each tab's current document would ask before it is left: "no" stands for the document, "yes" only for
    /// `beforeUnloadReprobe` (the probe runs the page's handlers and counts as user activation, so it is not run on
    /// every retry). Gone with the document, the view or the tab.
    @ObservationIgnored private var beforeUnloadAnswers = BeforeUnloadSchedule()
    /// Tabs whose probe is under way; a new document drops the tab, so a late answer is not kept for it.
    @ObservationIgnored private var beforeUnloadProbing: Set<TabID> = []
    /// Retries `releaseViews()` for tabs that were held; nil when no retry waits.
    @ObservationIgnored private var releaseRetryTask: Task<Void, Never>?
    @ObservationIgnored private var viewRelease = ViewRelease()
    /// When each tab was last on screen, stamped by the coordinator while the workspace is shown; gone with the tab.
    @ObservationIgnored var rest = TabRest()
    /// How long a held tab waits before its release is tried again.
    static let releaseRetry: Duration = .seconds(30)
    /// How long a release waits for a page's `beforeunload` handlers before taking it as not asking.
    static let beforeUnloadDeadline: Duration = .milliseconds(500)
    /// How long a page that asks before it is left is believed before it is asked again; layout self-checks shorten it.
    static var beforeUnloadReprobe: Duration = .seconds(300)
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
        registry: WebViewRegistry = WebViewRegistry(), defaultLibrary: LinkLibrary = LinkLibrary(),
        places: PlaceStore? = nil, icons: LinkIconCache? = nil
    ) {
        workspaceID = workspace
        self.store = store
        self.registry = registry
        self.places = workspace == Workspace.anonymousID ? nil : places
        self.icons = workspace == Workspace.anonymousID ? nil : icons
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
        self.places?.prune(keeping: Set(tabs.tabs.map(\.id)))
        if let directory = self.icons?.directory {
            // Off the main actor: icons of links removed in a run that could not remove theirs go. Only files
            // written before now, so an icon kept meanwhile stays; it never creates the directory, so a deletion
            // removing it meanwhile is safe.
            let links = Set((library.links(on: .pins) + library.links(on: .bookmarks)).map(\.id))
            let listed = Date.now
            Task.detached(priority: .utility) { LinkIconCache.prune(directory, keeping: links, before: listed) }
        }
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
            isAnyHeld = await release(candidates: tabs.tabs.map(\.id)) { _ in self.isShown }
            if isShown {
                viewRelease.stop()
                return
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

    /// The one release path (workspace leave, rest, memory pressure): each candidate not shown and with a view is
    /// released unless held. Shown and the view are checked again after every await, so a tab shown or rebuilt
    /// meanwhile is left alone. Returns whether any candidate was held.
    @discardableResult
    func release(candidates: [TabID], isShown: (TabID) -> Bool) async -> Bool {
        var isAnyHeld = false
        for id in candidates {
            let before = registry.webView(for: id)
            guard ViewRelease.step(isShown: isShown(id), hasView: before != nil, isHeld: false) != .skip,
                let view = before
            else { continue }
            let held = await isHeld(id)
            let step = ViewRelease.step(
                isShown: isShown(id), hasView: registry.webView(for: id) === view, isHeld: held || isHeldNow(id))
            switch step {
            case .skip: continue
            case .hold: isAnyHeld = true
            case .release: release(id)
            }
        }
        return isAnyHeld
    }

    /// The tabs that have a web view, in tab order.
    var liveTabs: [TabID] { tabs.tabs.compactMap { registry.webView(for: $0.id) != nil ? $0.id : nil } }

    /// A tab's capture, fullscreen or unsent work changed: a held background workspace tries its release again now, or
    /// once the pass running now ends.
    func holdStateChanged(_ id: TabID) {
        guard !isShown, releaseRetryTask != nil || viewRelease.isRunning else { return }
        Task { await releaseViews() }
    }

    /// The tab captures camera or microphone, is in fullscreen, is one of a popup and its opener that both still have
    /// a view, or has unsent work; then, only when none of that holds it, it plays media or (best effort) its page
    /// would ask before it is left.
    private func isHeld(_ id: TabID) async -> Bool {
        guard let view = registry.webView(for: id) else { return false }
        if isHeldNow(id) { return true }
        if await view.requestMediaPlaybackState() == .playing { return true }
        return await asksBeforeLeaving(id, view)
    }

    /// The holds known without asking the page; a sign-in challenge waiting for its sheet is one.
    private func isHeldNow(_ id: TabID) -> Bool {
        guard let view = registry.webView(for: id) else { return false }
        if view.cameraCaptureState != .none || view.microphoneCaptureState != .none { return true }
        if view.fullscreenState != .notInFullscreen { return true }
        if let opener = popupOpeners[id], registry.webView(for: opener) != nil { return true }
        if popupOpeners.contains(where: { $0.value == id && registry.webView(for: $0.key) != nil }) { return true }
        if controllers[id]?.isWaitingForSignIn == true { return true }
        return work[id]?.isHeld == true
    }

    /// Best effort: the main frame's `beforeunload` handlers cancel a synthetic event (`PageWorkScript`), asked as
    /// `beforeUnloadAnswers` allows. A page that checks `isTrusted` is not caught; one that cannot be asked, does not
    /// answer within `beforeUnloadDeadline`, or a view with no page counts as not asking.
    private func asksBeforeLeaving(_ id: TabID, _ view: WKWebView) async -> Bool {
        if let known = beforeUnloadAnswers.known(id, now: .now, every: Self.beforeUnloadReprobe) { return known }
        guard view.url != nil else { return false }
        beforeUnloadProbing.insert(id)
        let answer = await BoundedAnswer.first(within: Self.beforeUnloadDeadline, fallback: false) { reply in
            view.callAsyncJavaScript(
                PageWorkScript.beforeUnloadProbe, arguments: [:], in: nil,
                in: .world(name: PageWorkScript.worldName)
            ) { result in
                MainActor.assumeIsolated { reply((try? result.get()) as? Bool == true) }
            }
        }
        if beforeUnloadProbing.remove(id) != nil, registry.webView(for: id) === view {
            beforeUnloadAnswers.record(id, asks: answer, at: .now)
        }
        return answer
    }

    /// Whatever was learnt about the tab's document goes: a new one is asked afresh.
    private func forgetBeforeUnload(_ id: TabID) {
        beforeUnloadAnswers.forget(id)
        beforeUnloadProbing.remove(id)
    }

    // MARK: Unsent work

    /// A frame of the tab showing `view` reported its unsent work.
    func didReceiveWork(_ signal: PageWork.Signal, from view: WKWebView) {
        guard let id = tabs.tabs.first(where: { registry.webView(for: $0.id) === view })?.id else { return }
        changeWork(id) { $0.apply(signal) }
    }

    /// The tab's main frame began (true) or ended (false) loading a form submission.
    func formPost(inFlight: Bool, in id: TabID) {
        changeWork(id) { $0.formPost(inFlight: inFlight) }
    }

    /// The tab's main frame committed a new document, or its web content process ended: its documents' work drops.
    func resetWork(_ id: TabID) {
        forgetBeforeUnload(id)
        changeWork(id) { $0.reset() }
    }

    #if DEBUG
        /// Layout self-checks: whether the tab's page reports unsent work.
        func hasUnsentWork(_ id: TabID) -> Bool { work[id]?.isHeld == true }
    #endif

    /// Changes the tab's work, telling `holdStateChanged` when whether it holds changes.
    private func changeWork(_ id: TabID, _ change: (inout PageWork) -> Void) {
        guard tabs[id] != nil else { return }
        let old = work[id] ?? PageWork()
        var new = old
        change(&new)
        work[id] = new == PageWork() ? nil : new
        if new.isHeld != old.isHeld { holdStateChanged(id) }
    }

    /// Destroys the tab's web view; the tab keeps its URL and title, and its page's interaction state waits in
    /// memory for the view to be rebuilt, and on disk (`places`) for a relaunch.
    private func release(_ id: TabID) {
        guard registry.webView(for: id) != nil else { return }
        // A resting tab comes back on the page it showed, as after Go Back, and keeps that page's place.
        goBackFromPlainHTTP(id)
        guard let tab = tabs[id] else { return }
        controllers[id]?.didDeselect()
        controllers[id]?.cancelChallenges()
        controllers[id] = nil
        let state = registry.release(id)
        work[id] = nil
        resetFingerprintReads(id)
        forgetBeforeUnload(id)
        if tab.url != nil, let state { savedStates[id] = state }
        keepPlace(of: tab, state: state as? Data, scrollY: scrolls.removeValue(forKey: id)?.y)
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
    /// browser) with the address and title, and the `place` a move carries when this workspace keeps places, its web
    /// view built when a window shows it. A Lodge page already open here is that tab instead.
    func receive(url: URL, title: String, place: TabPlace? = nil) -> TabID {
        if let page = LodgePage(url: url), let shown = tab(showing: page) { return shown.id }
        let tab = BrowserTab(store: newTabStore(), url: url, title: title, isLive: false)
        changeTabs { $0.open(tab) }
        if let places, let place {
            do {
                try places.write(place, for: tab.id)
            } catch {
                Self.placesLogger.error("Cannot keep a moved tab's place: \(error.localizedDescription, privacy: .public)")
            }
        }
        return tab.id
    }

    /// The first tab of this workspace showing `page`: the dedupe key.
    func tab(showing page: LodgePage) -> BrowserTab? { tabs.tabs.first { $0.lodgePage == page } }

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

    // MARK: Fingerprint

    /// The tab's fingerprint key and exceptions (D3): an anonymous tab's store's, else its workspace's from the
    /// coordinator; nil for an unknown tab, and with no coordinator (previews).
    func fingerprintSettings(for id: TabID) -> FingerprintSettings? {
        tabs[id].flatMap { fingerprintSettings(on: $0.store) }
    }

    /// The key and exceptions tabs on `store` use: an anonymous tab's store's while something holds it, else the
    /// workspace's. Reading them is observed through `fingerprintExceptionsRevision`.
    func fingerprintSettings(on store: StoreRef) -> FingerprintSettings? {
        _ = fingerprintExceptionsRevision
        if case .ephemeral = store { return registry.isHeld(store) ? registry.fingerprint(for: store) : nil }
        return placement?.fingerprint(for: workspaceID)
    }

    /// Turns protection on or off for `site` (D7): the workspace's exception, saved with the session, or for an
    /// anonymous tab's `store` its own, in memory. Every tab on `store` whose view is at `site` gets its scripts again
    /// and reloads. Never asks.
    func setFingerprintProtection(_ on: Bool, for site: String, on store: StoreRef) {
        if case .ephemeral = store {
            guard registry.isHeld(store) else { return }
            registry.setFingerprint(off: !on, site, for: store)
        } else {
            placement?.setFingerprint(off: !on, site, for: workspaceID)
        }
        fingerprintExceptionsRevision += 1
        for tab in tabs.tabs where tab.store == store && controllers[tab.id] != nil && fingerprintSite(tab.id) == site {
            reinstallFingerprint(tab.id)
            reload(tab.id)
        }
    }

    /// The protection page in `page` now shows `site`, as read in `tab` (D5); with no site, it shows none.
    func setProtectionTarget(for page: TabID, site: String?, tab: TabID?) {
        var target: ProtectionTarget?
        if let site, let source = tab.flatMap({ tabs[$0] }) {
            target = ProtectionTarget(site: site, tab: source.id, store: source.store)
        }
        if protectionTargets[page] != target { protectionTargets[page] = target }
    }

    /// What the protection page in `page` was opened for, while the tab it was read in is still open.
    func protectionTarget(for page: TabID) -> ProtectionTarget? {
        protectionTargets[page].flatMap { tabs[$0.tab] != nil ? $0 : nil }
    }

    /// The tab's site exception changed: its view's scripts are installed again for documents loaded from now on.
    /// `setFingerprintProtection` calls it, then reloads the tab.
    func reinstallFingerprint(_ id: TabID) {
        controllers[id]?.reinstallScripts()
    }

    /// A frame of the tab showing `view` read `api`.
    func didReadFingerprint(_ api: FingerprintAPI, from view: WKWebView) {
        guard let id = tabs.tabs.first(where: { registry.webView(for: $0.id) === view })?.id,
            fingerprintReads[id]?.contains(api) != true
        else { return }
        fingerprintReads[id, default: []].insert(api)
    }

    /// The tab's main frame committed a new document, or its web content process ended: nothing is read yet.
    func resetFingerprintReads(_ id: TabID) {
        if fingerprintReads[id] != nil { fingerprintReads[id] = nil }
    }

    /// The site the tab's view is seeded for (D1); a tab with no view, its address's site. Nil for none (blank,
    /// `lodge:`).
    func fingerprintSite(_ id: TabID) -> String? {
        controllers[id]?.topSite ?? FingerprintSite.of(tabs[id]?.url, inheriting: nil)
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
    /// `topSite`: the site its scripts are first seeded for (D7). `sendsForm`: the popup opens for a sent form
    /// (`target=_blank`), so its view counts as having sent one.
    func openPopup(
        from source: TabID, configuration: WKWebViewConfiguration, topSite: String? = nil, sendsForm: Bool = false
    ) -> WKWebView? {
        guard tabs[source] != nil else { return nil }
        let popup = BrowserTab(store: newTabStore(popupOf: source))
        popupOpeners[popup.id] = source
        let view = append(popup, configuration: configuration, topSite: topSite, load: false)
        if sendsForm { didSendForm(popup.id) }
        placement?.didOpen(popup.id, in: workspaceID, from: source)
        return view
    }

    /// Appends `tab` and builds its web view, loading `tab.url` when `load` is true; which window shows it is the
    /// caller's. `topSite` is a popup's, with its `configuration` (`view(for:)`).
    @discardableResult
    func append(
        _ tab: BrowserTab, configuration: WKWebViewConfiguration? = nil, topSite: String? = nil, load: Bool
    ) -> LodgeWebView? {
        var tab = tab
        tab.isLive = false
        changeTabs { $0.open(tab) }
        return view(for: tab.id, configuration: configuration, topSite: topSite, load: load)
    }

    /// A window now shows `id` in place of `previous`: the previous tab's sheet ends and it stops taking focus when
    /// shown, unless another window still shows it; the folders above the new tab's bookmark open, it gets its web
    /// view, and its waiting sign-in challenge its sheet.
    func didSelect(_ id: TabID?, previous: TabID?, previousStillShown: Bool) {
        if let previous, previous != id, !previousStillShown {
            controllers[previous]?.didDeselect()
            registry.webView(for: previous)?.focusesWhenShown = false
        }
        guard let id else { return }
        if let link = tabs[id]?.link { changeLibrary { $0.reveal(link) } }
        view(for: id)
        controllers[id]?.didSelect()
    }

    /// The tab's web view, building it (registry + TabController) when the tab has none, then marking the tab
    /// live. Loads `tab.url` when it built the view and `load` is true. Nil for an unknown tab, and for a tab on a
    /// `lodge:` address, which never has one: the single guard keeping web views off Lodge pages.
    /// The ONLY place that sets `isLive = true`. The view's scripts are first seeded (D7) for `topSite` with a popup's
    /// `configuration`, else for the tab's address, so a restored or resting tab's new view gets them too.
    @discardableResult
    func view(
        for id: TabID, configuration: WKWebViewConfiguration? = nil, topSite: String? = nil, load: Bool = true
    ) -> LodgeWebView? {
        guard let tab = tabs[id], !LodgePage.isLodge(tab.url) else { return nil }
        if let view = registry.webView(for: id) { return view }
        let isRestoring = restoredTabs.remove(id) != nil
        let saved = savedStates.removeValue(forKey: id)
        // Only WebKit's own state from memory carries a sent form along; every other view starts clean.
        if !(load && saved != nil) { sentForm.remove(id) }
        let onDisk = load && saved == nil ? places?.read(id)?.wake(at: tab.url) : nil
        let view = registry.make(
            for: id, store: tab.store, configuration: configuration, zoom: zoom[id] ?? PageZoom.actual, model: self)
        update(id) { $0.isLive = true }
        // Built once the tab is listed, so the controller's initial KVO values reach it.
        let controller = TabController(
            tab: id, webView: view, model: self, faviconSession: registry.faviconSession(for: tab.store),
            topSite: configuration == nil ? FingerprintSite.of(tab.url, inheriting: nil) : topSite)
        controllers[id] = controller
        if load { controller.wakeURL = tab.url }
        if load, let saved {
            controller.browserWillLoad()
            controller.expectsRestoreCommit = true
            view.interactionState = saved
        } else if load, case .state(let state) = onDisk {
            controller.browserWillLoad()
            controller.expectsRestoreCommit = isRestoring
            view.interactionState = state
        } else if load, let url = tab.url {
            if case .load(_, let y?) = onDisk { controller.restoreScroll(to: y, at: url) }
            if let link = tab.link.flatMap(savedLink), link.url == url { controller.linkWillLoad() }
            controller.browserWillLoad()
            let navigation = view.load(URLRequest(url: url))
            if isRestoring { controller.restoreNavigation = navigation }
        }
        return view
    }

    // MARK: Places on disk

    /// Writes the tab's place (D5) when the workspace keeps places and the tab has a page: WebKit's `state` when its
    /// view never sent a form, else only the address, title and scroll position. Failures are logged.
    private func keepPlace(of tab: BrowserTab, state: Data?, scrollY: Double?, seen: Date = .now) {
        guard let places, let url = tab.url, !LodgePage.isLodge(url) else { return }
        let place = TabPlace(
            url: url, title: tab.title, scrollY: scrollY, state: state, sentForm: sentForm.contains(tab.id))
        do {
            try places.write(place, for: tab.id, seen: seen)
        } catch {
            Self.placesLogger.error("Cannot keep a tab's place: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Quitting: every tab still awake keeps its place too, least recently seen first so the caps evict in that
    /// order; resting tabs already did when they rested.
    func keepLivePlaces() {
        guard places != nil else { return }
        let live = liveTabs
        let oldest = rest.oldestFirst(live)
        let start = Date.now
        for (index, id) in (oldest + live.filter { !oldest.contains($0) }).enumerated() {
            guard let tab = tabs[id], let view = registry.webView(for: id) else { continue }
            keepPlace(
                of: tab, state: view.interactionState as? Data, scrollY: scrolls[id]?.y,
                seen: start.addingTimeInterval(Double(index) / 1_000))
        }
    }

    /// The tab's place as it would be kept on disk, for a move to another workspace; nil when this workspace keeps
    /// no places (Anonymous) or the tab has no page.
    func place(of id: TabID) -> TabPlace? {
        guard let places, let tab = tabs[id], let url = tab.url, !LodgePage.isLodge(url) else { return nil }
        let sent = sentForm.contains(id)
        if let view = registry.webView(for: id) {
            return TabPlace(
                url: url, title: tab.title, scrollY: scrolls[id]?.y, state: view.interactionState as? Data,
                sentForm: sent)
        }
        if let kept = places.read(id), kept.url == url { return kept }
        guard let saved = savedStates[id] as? Data else { return nil }
        return TabPlace(url: url, title: tab.title, scrollY: nil, state: saved, sentForm: sent)
    }

    /// The tab's view navigated for a sent form, in its page or a frame (`.formSubmitted`/`.formResubmitted`).
    func didSendForm(_ id: TabID) {
        guard tabs[id] != nil else { return }
        sentForm.insert(id)
    }

    /// The main frame of the tab showing `view` reported its scroll position.
    func didReceivePlace(_ place: PageWorkScript.Place, from view: WKWebView) {
        guard let id = tabs.tabs.first(where: { registry.webView(for: $0.id) === view })?.id else { return }
        scrolls[id, default: MainScroll()].apply(place)
    }

    #if DEBUG
        /// Layout self-checks: whether the tab's view counts as having sent a form, and its reported scroll.
        func hasSentForm(_ id: TabID) -> Bool { sentForm.contains(id) }
        func reportedScroll(_ id: TabID) -> Double? { scrolls[id]?.y }
    #endif

    /// Every change to `tabs` goes through here: a tab that closes loses everything kept for it. A new tab holds its
    /// store; a closed one lets go of it, and its web view goes, on the next main-actor turn, so a WebKit callback
    /// running on it (a popup's opener) returns first. A change putting a `lodge:` address on a tab with a web view
    /// is dropped whole.
    private func changeTabs(_ change: (inout TabList) -> Void) {
        let before = tabs.tabs.map(\.id)
        var next = tabs
        change(&next)
        guard !next.tabs.contains(where: { putsLodgeOnAWebView(tabs[$0.id], $0) }) else { return }
        tabs = next
        let kept = Set(before)
        for tab in tabs.tabs where !kept.contains(tab.id) { registry.attach(tab: tab.id, to: tab.store) }
        let dropped = before.filter { tabs[$0] == nil }
        guard !dropped.isEmpty else { return }
        for id in dropped {
            controllers[id]?.cancelChallenges()
            controllers[id] = nil
            restoredTabs.remove(id)
            savedStates[id] = nil
            sentForm.remove(id)
            scrolls[id] = nil
            places?.remove(id)
            popupOpeners[id] = nil
            work[id] = nil
            rest.forget(id)
            forgetBeforeUnload(id)
            if protectionTargets[id] != nil { protectionTargets[id] = nil }
            if plainHTTPWarnings[id] != nil { plainHTTPWarnings[id] = nil }
            plainHTTPBackForward.remove(id)
            popupOpeners = popupOpeners.filter { $0.value != id }
            historyRecorder?.send(.closed(tab: id))
            if loadProgress[id] != nil { loadProgress[id] = nil }
            if favicons[id] != nil { favicons[id] = nil }
            if security[id] != nil { security[id] = nil }
            if zoom[id] != nil { zoom[id] = nil }
            resetFingerprintReads(id)
        }
        Task { @MainActor [registry] in
            registry.detach(tabs: dropped)
        }
    }

    /// Writes to `tabs` only when the tab really changes, so unchanged KVO ticks do not redraw the window. A change
    /// putting a `lodge:` address on a tab with a web view is dropped, so no web view hides behind a Lodge page.
    func update(_ id: TabID, _ change: (inout BrowserTab) -> Void) {
        guard let old = tabs[id] else { return }
        var tab = old
        change(&tab)
        if tab != old, !putsLodgeOnAWebView(old, tab) { tabs.update(id) { $0 = tab } }
    }

    private func putsLodgeOnAWebView(_ old: BrowserTab?, _ new: BrowserTab) -> Bool {
        old?.url != new.url && LodgePage.isLodge(new.url) && registry.webView(for: new.id) != nil
    }

    /// Shows the tab's icon. A link's tab on that link's own load also keeps it for the link, on disk (D2); in
    /// Anonymous a bookmark's tab stores it in the bookmark instead, in memory, whatever page it is on.
    func setFavicon(_ image: NSImage?, for id: TabID) {
        guard let tab = tabs[id], favicons[id] !== image else { return }
        favicons[id] = image
        guard let image, let link = tab.link else { return }
        if isAnonymous {
            if library.links(on: .bookmarks).contains(where: { $0.id == link }) { storeIcon(image, in: link) }
        } else if controllers[id]?.isOnLinkLoad == true {
            keepIcon(image, for: link)
        }
    }

    /// The row's icon: its open tab's favicon, else a shared pin's from Default, else the icon the link keeps.
    func favicon(for item: SidebarItem) -> NSImage? {
        if let tab = item.tab, let image = favicons[tab.id] { return image }
        guard case .link(let link, let shelf, _) = item else { return nil }
        if shelf == .pins, let sharedPins { return sharedPins.pinFavicon(link.id) }
        return storedIcon(link.id, data: isAnonymous ? link.icon : icons?.icon(for: link.id))
    }

    /// The icon the link keeps on disk, its file read the first time and decoded once; nil when it keeps none.
    func keptIcon(for link: UUID) -> NSImage? {
        storedIcon(link, data: icons?.icon(for: link))
    }

    private func storedIcon(_ link: UUID, data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let cached = storedIcons[link], cached.data == data { return cached.image }
        guard let cgImage = LinkIcon.image(from: data) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        storedIcons[link] = (data, image)
        return image
    }

    /// Memory pressure (D4): the decoded link icons go; each is decoded again from its kept bytes when next drawn.
    func dropRebuildableCaches() {
        storedIcons.removeAll()
    }

    /// A suggestion row's icon from what is already at hand, never fetched: the open tab's favicon, else that of a
    /// tab open on the row's page, else the stored icon of a pin or bookmark on it; nil for the search row.
    func suggestionIcon(for suggestion: Suggestion) -> NSImage? {
        if case .openTab(let id) = suggestion.kind, let image = favicons[id] { return image }
        guard let url = suggestion.url else { return nil }
        if let tab = tabs.tabs.first(where: { $0.url == url && favicons[$0.id] != nil }) { return favicons[tab.id] }
        if let pin = pins.first(where: { $0.url == url }), let image = favicon(for: .link(pin, .pins, nil)) {
            return image
        }
        let bookmark = library.links(on: .bookmarks).first { $0.url == url }
        return bookmark.flatMap { favicon(for: .link($0, .bookmarks, nil)) }
    }

    private func storeIcon(_ image: NSImage, in link: UUID) {
        guard let data = Self.iconData(image) else { return }
        changeLibrary { $0.setIcon(link, data) }
    }

    /// Keeps `image` as the link's icon in `icons`, written only when its bytes differ from those kept.
    private func keepIcon(_ image: NSImage, for link: UUID) {
        guard let icons, savedLink(link) != nil, let data = Self.iconData(image) else { return }
        do {
            if try icons.write(data, for: link) { storedIcons[link] = (data, image) }
        } catch {
            Self.iconsLogger.error("Cannot keep a link's icon: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let iconsLogger = Logger(subsystem: "dev.lodge", category: "icons")

    private static func iconData(_ image: NSImage) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap(LinkIcon.png(from:))
    }

    func setProgress(_ progress: Double, for id: TabID) {
        if loadProgress[id] != progress { loadProgress[id] = progress }
    }

    func setSecurity(_ value: SiteSecurity, for id: TabID) {
        guard tabs[id] != nil, security[id] != value else { return }
        security[id] = value
    }

    // MARK: Links

    /// The pin or bookmark with `id` in this workspace's own library.
    private func savedLink(_ id: UUID) -> SavedLink? {
        library.links(on: .pins).first { $0.id == id } ?? library.links(on: .bookmarks).first { $0.id == id }
    }

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
        if let image = favicons[id] {
            // The tab shows the link's own URL, so its icon is the link's.
            if isAnonymous {
                if shelf == .bookmarks { storeIcon(image, in: link.id) }
            } else {
                keepIcon(image, for: link.id)
            }
        }
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

    /// Drops the link's row, or a folder with every row in it, with the icons they keep; an open tab of a removed
    /// link carries on as a loose tab.
    func removeLink(_ id: UUID) {
        let removed = Set(library.remove(id))
        for link in removed {
            icons?.remove(link)
            storedIcons[link] = nil
        }
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
    func newFolder(in parent: UUID? = nil, title: String = String(localized: "New Folder")) -> UUID? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder: BookmarkFolder?
        changeLibrary { library in
            let parent = parent ?? library.bookmarks.id
            folder = library.addFolder(name.isEmpty ? String(localized: "New Folder") : name, in: parent)
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

    /// Loads `url` in the tab; false, changing nothing, for an unknown tab or a `lodge:` address. The address is set
    /// before the view is asked for, so a Lodge page's tab gets a fresh web view with no back entry, and drops its
    /// link, so that pin or bookmark still leads to the Lodge page.
    func load(_ url: URL, in id: TabID) -> Bool {
        guard let tab = tabs[id], !LodgePage.isLodge(url) else { return false }
        let leavesLodge = LodgePage.isLodge(tab.url)
        update(id) {
            $0.url = url
            if leavesLodge { $0.link = nil }
        }
        guard let view = view(for: id, load: false) else { return false }
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

    /// Stops the tab's load; no delegate call follows, so its controller is told here (D1).
    func stopLoading(_ id: TabID) {
        registry.webView(for: id)?.stopLoading()
        controllers[id]?.didStop()
    }

    // MARK: Plain http

    #if DEBUG
        /// Layout self-checks: loopback hosts are warned about too, so a check can show the warning with a local
        /// server.
        static var selfCheckWarnsLoopback = false
    #endif

    /// Whether the tab's main frame loading `url` is stopped for the warning (D8): plain http to a host the tab's store
    /// has not allowed, not on this computer.
    func warnsPlainHTTP(_ url: URL, in id: TabID) -> Bool {
        guard let store = tabs[id]?.store else { return false }
        var exemptsLoopback = true
        #if DEBUG
            exemptsLoopback = !Self.selfCheckWarnsLoopback
        #endif
        return PlainHTTP.warns(url, allowed: registry.plainHTTPHosts(for: store), exemptsLoopback: exemptsLoopback)
    }

    /// The tab's main-frame load of `url` was stopped for the warning: it shows in place of the page, the address
    /// field shows `url` and the security indicator says it is not secure. `backForward`: the load was a back/forward
    /// one. A later warning replaces it.
    func showPlainHTTPWarning(_ url: URL, for id: TabID, backForward: Bool = false) {
        guard tabs[id] != nil else { return }
        if backForward { plainHTTPBackForward.insert(id) } else { plainHTTPBackForward.remove(id) }
        if plainHTTPWarnings[id] != url { plainHTTPWarnings[id] = url }
        update(id) { $0.url = url }
        setSecurity(SiteSecurity(url: url, hasOnlySecureContent: false), for: id)
    }

    /// Go Back: the warning goes and the tab shows its page as it was, its address and security again the view's; a
    /// view that never showed a page keeps the address it was woken at (blank page, Reload loads it), and a new tab
    /// is blank again.
    func goBackFromPlainHTTP(_ id: TabID) {
        guard plainHTTPWarnings[id] != nil else { return }
        plainHTTPWarnings[id] = nil
        plainHTTPBackForward.remove(id)
        if let controller = controllers[id] {
            controller.showCurrentPage()
        } else {
            update(id) { $0.url = nil }
        }
    }

    /// Another main-frame load the tab let through ends its warning: the address shows where it goes.
    func endPlainHTTPWarning(_ id: TabID, loading url: URL?) {
        guard plainHTTPWarnings[id] != nil else { return }
        goBackFromPlainHTTP(id)
        if let url, !LodgePage.isLodge(url) { update(id) { $0.url = url } }
    }

    /// Continue: the warned page's host is allowed for the tab's store, until Lodge quits (an anonymous tab's, until
    /// its store goes), and the page loads: a back/forward load goes to the nearest history entry at its URL while the
    /// view still has one, any other loads the URL afresh.
    func continueToPlainHTTP(_ id: TabID) {
        guard let url = plainHTTPWarnings.removeValue(forKey: id), let tab = tabs[id] else { return }
        let backForward = plainHTTPBackForward.remove(id) != nil
        if let host = PlainHTTP.host(of: url) { registry.allowPlainHTTP(host, for: tab.store) }
        if backForward, let view = registry.webView(for: id),
            let item = (view.backForwardList.backList.reversed() + view.backForwardList.forwardList).first(where: {
                $0.url == url
            })
        {
            update(id) { $0.url = url }
            view.go(to: item)
        } else {
            _ = load(url, in: id)
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
    /// The workspace's fingerprint key and exceptions; nil for Anonymous (D3).
    func fingerprint(for workspaceID: UUID) -> FingerprintSettings?
    /// Turns the workspace's protection off (or back on) for `site`, saved with the session (D7).
    func setFingerprint(off: Bool, _ site: String, for workspaceID: UUID)
}

/// What the protection page is opened for (D5): the site, the tab it was read in, and that tab's store, whose
/// exceptions an Anonymous page shows.
struct ProtectionTarget: Equatable {
    let site: String
    let tab: TabID
    let store: StoreRef
}
