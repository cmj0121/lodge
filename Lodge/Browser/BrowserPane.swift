import AppKit
import LodgeKit
import WebKit

/// One window's view of the active workspace: the tab the window shows and every action on that tab or on the
/// window's floating surfaces. The coordinator builds one per render (`pane(for:)`); it holds no state of its own.
@MainActor
struct BrowserPane {
    let model: BrowserModel
    let window: WindowState
    unowned let coordinator: WorkspaceCoordinator

    /// The tab this window shows.
    var selectedID: TabID? { coordinator.selections.shown(in: window.id) }

    var selected: BrowserTab? { selectedID.flatMap { model.tabs[$0] } }

    /// The window's title: "Anonymous" whatever its tab shows, else the shown tab's title.
    var windowTitle: String { model.isAnonymous ? Workspace.anonymousName : selected?.displayTitle ?? "Lodge" }

    /// The shown page's security; `.none` with no tab shown.
    var selectedSecurity: SiteSecurity { selectedID.flatMap { model.security[$0] } ?? .none }

    // MARK: Tabs

    /// Whether another window shows the tab, so selecting it here brings that window forward (D4).
    func isShownElsewhere(_ tab: TabID) -> Bool {
        coordinator.selections.window(showing: tab).map { $0 != window.id } == true
    }

    /// Shows the tab in this window, building its web view when it has none; a tab another window shows brings that
    /// window forward instead, and this window keeps its own tab (D4).
    func select(_ id: TabID) {
        switch coordinator.select(id, in: window) {
        case .selected: model.view(for: id)
        case .shownIn(let other): coordinator.window(for: other).map(coordinator.bringForward)
        case .unknown: break
        }
    }

    func selectNextTab() { step(1) }

    func selectPreviousTab() { step(-1) }

    /// Shows the next entry in the direction of `offset`, passing over tabs another window shows; nothing when every
    /// other entry is one.
    private func step(_ offset: Int) {
        let sidebar = model.sidebar
        var from = selectedID
        var passed = Set<TabID>()
        while let target = sidebar.target(offset, from: from) {
            guard case .tab(let id) = target, isShownElsewhere(id) else { return activate(target) }
            guard passed.insert(id).inserted else { return }
            from = id
        }
    }

    /// Shows the row's target; a shared pin opens in Default, which every window switches to.
    func activate(_ target: SidebarSections.Target) {
        switch target {
        case .tab(let id): select(id)
        case .link(let link):
            if let sharedPins = model.sharedPins, sharedPins.pins.contains(where: { $0.id == link.id }) {
                sharedPins.openPin(link, from: window)
            } else {
                openLink(link)
            }
        }
    }

    /// Shows the link's open tab, else opens a fresh tab on the link's URL here, loaded unless `load` is false
    /// (layout renders, so no request goes out). The tab keeps the link while it navigates.
    func openLink(_ link: SavedLink, load: Bool = true) {
        if let tab = model.tabs.tab(forLink: link.id) {
            select(tab.id)
        } else {
            open(model.tab(for: link), load: load)
        }
    }

    /// Closes the tab with every popup it opened; a window showing one of them moves to its sidebar neighbour.
    func close(_ id: TabID) { model.close(id) }

    func closeSelectedTab() {
        closeFloatingSurfaces()
        if let id = selectedID { close(id) }
    }

    /// A History window entry: when another window shows a tab on exactly this URL, that window comes forward (D4);
    /// otherwise the page opens in a new tab shown here, as before. A URL that is not a web page opens nothing.
    func open(historyURL url: URL) {
        guard NewTabPolicy.allowsFromHistory(url) else { return }
        if let shown = model.tabs.tabs.first(where: { $0.url == url && isShownElsewhere($0.id) }) {
            return select(shown.id)
        }
        open(BrowserTab(store: model.newTabStore(), url: url), load: true)
    }

    /// Appends the tab to the workspace and shows it in this window.
    private func open(_ tab: BrowserTab, load: Bool) {
        model.append(tab, load: load)
        coordinator.opened(tab.id, in: model, window: window)
    }

    private func openLoose(_ url: URL) {
        open(BrowserTab(store: model.newTabStore(), url: url), load: true)
    }

    // MARK: Navigation

    /// The shown tab's web view, built without loading when the tab has none.
    private var selectedView: LodgeWebView? { selectedID.flatMap { model.view(for: $0, load: false) } }

    /// Loads the address into the shown tab, or opens a loose tab on it when none is shown.
    func load(_ text: String) {
        guard let url = AddressInput.url(from: text) else { return }
        guard let id = selectedID else { return openLoose(url) }
        load(url, in: id)
        focusSelectedView()
    }

    /// Loads `url` in the tab; when the tab has no web view to load in, opens a loose tab on it instead.
    private func load(_ url: URL, in id: TabID) {
        if !model.load(url, in: id) { openLoose(url) }
    }

    func goBack() { selectedView?.goBack() }

    func goForward() { selectedView?.goForward() }

    func reload() {
        closeFloatingSurfaces()
        if let id = selectedID { model.reload(id) }
    }

    func stopLoading() { selectedView?.stopLoading() }

    /// Opens the location prompt for a new tab; the tab opens only when the prompt submits an address.
    func newTab() {
        hideShortcutHelp()
        window.workspaceEditor = nil
        window.locationPrompt = .newTab
    }

    /// Opens the location prompt on the shown tab's address, or for a new tab when none is shown.
    func focusAddressBar() {
        hideShortcutHelp()
        window.workspaceEditor = nil
        window.locationPrompt = selectedID.map { .current($0) } ?? .newTab
    }

    // MARK: Location prompt

    /// Goes where the prompt's text leads: a new tab shown here, or its tab (a new one if that tab has closed since).
    /// Text that makes no address (blank) leaves the prompt open.
    func submitLocation(_ text: String) {
        guard let prompt = window.locationPrompt, let url = AddressInput.url(from: text) else { return }
        window.locationPrompt = nil
        if case .current(let id) = prompt, model.tabs[id] != nil {
            load(url, in: id)
        } else if case .newTab = prompt, let blank = selected, blank.url == nil, !blank.isLoading {
            // The blank tab an empty window or closing the last tab leaves takes the page, so no empty New Tab row
            // is left behind.
            load(url, in: blank.id)
        } else {
            openLoose(url)
        }
        focusSelectedView()
    }

    /// Closes the prompt and hands the keys back to the page, as closing Find does.
    func cancelLocationPrompt() {
        guard window.locationPrompt != nil else { return }
        window.locationPrompt = nil
        focusSelectedView()
    }

    /// Closes the shortcut overlay, the location prompt and the workspace sheet. Every catalog shortcut's action calls
    /// it first, so a key pressed over any of them never acts out of sight behind it.
    func closeFloatingSurfaces() {
        hideShortcutHelp()
        cancelLocationPrompt()
        closeWorkspaceEditor()
    }

    // MARK: Workspace sheet

    /// Opens the workspace sheet in place of every other floating surface (find, the location prompt, the shortcut
    /// overlay, the Downloads popover) and takes the keys from the page under it.
    func showWorkspaceEditor(_ editor: WorkspaceEditor) {
        window.locationPrompt = nil
        window.isShortcutHelpVisible = false
        window.dismissFind()
        window.isDownloadsVisible = false
        window.workspaceEditor = editor
        if let window = selectedView?.window { window.makeFirstResponder(nil) }
    }

    /// Closes the sheet and hands the keys back to the page, as closing the location prompt does.
    func closeWorkspaceEditor() {
        guard window.workspaceEditor != nil else { return }
        finishWorkspaceEditor()
    }

    /// The sheet is done: closed if still open, and the keys go to the page, also when Create already closed it by
    /// switching to the new workspace.
    func finishWorkspaceEditor() {
        window.workspaceEditor = nil
        focusSelectedView()
    }

    /// Makes the shown page first responder; a view not in a window yet (a tab just opened) takes focus when
    /// SwiftUI puts it in one.
    private func focusSelectedView() {
        guard let view = selectedView else { return }
        if let window = view.window {
            window.makeFirstResponder(view)
        } else {
            view.focusesWhenShown = true
        }
    }

    // MARK: Pins and bookmarks

    func bookmarkSelectedTab() {
        closeFloatingSurfaces()
        if let id = selectedID { model.addLink(.bookmarks, from: id) }
    }

    /// The pin holding the shown tab's page, matched by URL so a bookmark's tab finds its pin too.
    private var selectedPin: SavedLink? {
        guard let url = selected?.url else { return nil }
        return model.pins.first { $0.url == url }
    }

    /// The shown tab's page is one of the pins.
    var isSelectedTabPinned: Bool { selectedPin != nil }

    /// Pins the shown tab's page, or unpins it; the page stays open, and a bookmark's tab keeps its bookmark.
    func togglePinSelectedTab() {
        closeFloatingSurfaces()
        if let pin = selectedPin {
            model.unpin(pin.id)
        } else if let id = selectedID {
            model.addLink(.pins, from: id)
        }
    }

    // MARK: Zoom

    /// The shown tab's zoom, nil when it has no page.
    private var selectedPageZoom: Double? {
        guard let id = selectedID, model.tabs[id]?.url != nil else { return nil }
        return model.zoom[id] ?? PageZoom.actual
    }

    var canZoomIn: Bool { selectedPageZoom.map(PageZoom.canZoomIn) == true }

    var canZoomOut: Bool { selectedPageZoom.map(PageZoom.canZoomOut) == true }

    var canResetZoom: Bool { selectedPageZoom.map { $0 != PageZoom.actual } == true }

    func zoomIn() {
        closeFloatingSurfaces()
        if canZoomIn { setSelectedZoom(PageZoom.zoomedIn) }
    }

    func zoomOut() {
        closeFloatingSurfaces()
        if canZoomOut { setSelectedZoom(PageZoom.zoomedOut) }
    }

    func resetZoom() {
        closeFloatingSurfaces()
        if canResetZoom { setSelectedZoom { _ in PageZoom.actual } }
    }

    private func setSelectedZoom(_ next: (Double) -> Double) {
        guard let id = selectedID, let current = selectedPageZoom else { return }
        model.setZoom(next(current), for: id)
    }

    // MARK: Downloads

    /// Each sidebar mode anchors the Downloads popover on its own button, so it closes before the mode changes rather
    /// than leave the flag set with its anchor gone; ⌘J then opens it on the new button.
    func closeDownloadsForModeChange() { window.isDownloadsVisible = false }

    func toggleDownloads() {
        closeFloatingSurfaces()
        window.isDownloadsVisible.toggle()
    }

    // MARK: Shortcut help

    /// Opens the overlay and takes the keys from the page under it, so Esc and typing reach the overlay.
    func showShortcutHelp() {
        window.locationPrompt = nil
        window.workspaceEditor = nil
        window.isShortcutHelpVisible = true
        if let window = selectedView?.window { window.makeFirstResponder(nil) }
    }

    /// Closes the overlay and hands the keys back to the page, as closing Find does.
    func hideShortcutHelp() {
        guard window.isShortcutHelpVisible else { return }
        window.isShortcutHelpVisible = false
        if let view = selectedView { view.window?.makeFirstResponder(view) }
    }

    func toggleShortcutHelp() {
        if window.isShortcutHelpVisible { hideShortcutHelp() } else { showShortcutHelp() }
    }

    // MARK: Find

    func showFind() {
        closeFloatingSurfaces()
        window.isFindVisible = true
        if window.findMissed { window.findMissed = false }
        window.findFocusRequest += 1
    }

    func hideFind() {
        window.dismissFind()
        if let view = selectedView { view.window?.makeFirstResponder(view) }
    }

    func findNext() { find(backwards: false) }

    func findPrevious() { find(backwards: true) }

    /// Searches for the find text unless it was already searched for.
    func findIfChanged() {
        if window.findText != window.lastSearchedText { findNext() }
    }

    private func find(backwards: Bool) {
        let text = window.findText
        window.lastSearchedText = text
        guard !text.isEmpty, let view = selectedView else {
            if window.findMissed { window.findMissed = false }
            return
        }
        if !window.isFindVisible { showFind() }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        view.find(text, configuration: config) { [window] result in
            window.findMissed = !result.matchFound
        }
    }
}
