#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI
    import WebKit

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, find
    /// open, and the shortcut overlay and the location prompt in light and dark), workspace colours and
    /// Anonymous's dark window, the Settings tab, the History tab from an in-memory history, and the Downloads popover and button
    /// from sample items, to PNG files off screen, then exits. It never shows a window or takes focus,
    /// so it can run while someone uses the machine. The only download is a `data:` URL saved to a temporary folder;
    /// the fingerprint check's pages come from a server on the loopback interface that stops with it.
    @MainActor
    enum LayoutRenderer {
        static func runIfRequested() {
            guard UserDefaults.standard.bool(forKey: "renderLayout") else { return }
            NSApplication.shared.setActivationPolicy(.prohibited)
            let directory = FileManager.default.temporaryDirectory.appending(path: "LodgeLayout")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for mode in SidebarMode.allCases {
                render(mode, find: false, to: directory.appending(path: "layout-\(mode.rawValue).png"))
            }
            render(.rail, find: true, to: directory.appending(path: "layout-find.png"))
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                render(
                    .expanded, find: false, shortcutHelp: true, appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-shortcuts-\(name).png"))
                render(
                    .expanded, find: false, prompt: .current, appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-location-\(name).png"))
                render(
                    .expanded, find: false, prompt: .newTab, appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-location-new-\(name).png"))
            }
            renderWorkspace(to: directory.appending(path: "layout-workspace.png"))
            renderWorkspaceUI(in: directory)
            renderAnonymous(in: directory)
            renderTheme(in: directory)
            checkAppearance()
            checkWorkspaceAppearance()
            checkTheme()
            checkDeletion(to: directory.appending(path: "layout-delete.png"))
            checkAnonymous()
            checkPrivateDownloadRow()
            checkSharedPins(to: directory.appending(path: "layout-shared-pins.png"))
            checkMoveTabs()
            checkTwoWindows()
            checkShownElsewhere(in: directory)
            checkStepSkipsShownElsewhere()
            checkExternalLinks()
            checkLodgePages()
            checkWorkHolds()
            checkResting()
            checkMemoryPressure()
            checkPressureKeepsSessionStore()
            checkReleasedViewGoes()
            checkPlaces()
            checkKeptIcons()
            checkFingerprint()
            checkAuth()
            checkPlainHTTP()
            checkUserAgent()
            renderSettings(in: directory)
            renderProtection(in: directory)
            renderAuth(in: directory)
            renderPlainHTTP(in: directory)
            renderHistory(in: directory)
            renderDownloads(in: directory)
            print(directory.path(percentEncoded: false))
            exit(0)
        }

        private static func render(
            _ mode: SidebarMode, find: Bool, shortcutHelp: Bool = false, prompt: PromptRender? = nil,
            appearance: NSAppearance? = nil, to url: URL
        ) {
            // A throwaway defaults suite, so rendering never changes the user's saved sidebar mode.
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            let pane = firstPane(coordinator)
            let model = pane.model
            // Opens the sample's folder, so the render shows a nested bookmark.
            for case .folder(let folder) in model.library.bookmarks.children { model.setFolderExpanded(folder.id, true) }
            if let bookmark = model.library.links(on: .bookmarks).first { pane.openLink(bookmark, load: false) }
            // An in-memory manager over one running sample, so the sidebar shows the Downloads ring.
            let downloads = DownloadManager(directory: nil, defaults: defaults)
            let running = sampleDownloads.filter { $0.state == .running && $0.totalBytes != nil }
            downloads.restore(DownloadList(items: running))
            model.downloads = downloads
            if find {
                pane.showFind()
                pane.window.findText = "lodge"
            }
            pane.window.isShortcutHelpVisible = shortcutHelp
            switch prompt {
            case .newTab: pane.newTab()
            case .current: pane.focusAddressBar()
            case nil: break
            }
            snapshot(
                root(coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
                appearance: appearance, to: url)
        }

        /// The workspace bar over Default and two custom workspaces, the second shown, in both sidebar modes and both
        /// appearances; then the New Workspace, Change Icon and Rename sheets over it.
        private static func renderWorkspaceUI(in directory: URL) {
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                _ = try? coordinator.create(name: "Personal", symbol: "house")
                guard let work = try? coordinator.create(name: "Work", symbol: "briefcase") else { return }
                for mode in SidebarMode.allCases {
                    defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
                    snapshot(
                        root(coordinator).defaultAppStorage(defaults),
                        size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                        to: directory.appending(path: "layout-workspaces-\(mode.rawValue)-\(name).png"))
                }
                defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
                coordinator.windows[0].workspaceEditor = .create
                snapshot(
                    root(coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-sheet-\(name).png"))
                coordinator.windows[0].workspaceEditor = .changeIcon(work.id)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-icon-\(name).png"))
                coordinator.windows[0].workspaceEditor = .rename(work.id)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-rename-\(name).png"))
            }
        }

        /// Anonymous shown after Default and two custom workspaces: its bar tile and header in both sidebar modes and
        /// both appearances, and a Rename sheet opened for it anyway. Anonymous's History tab is drawn by
        /// `renderHistory`.
        private static func renderAnonymous(in directory: URL) {
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                _ = try? coordinator.create(name: "Personal", symbol: "house")
                _ = try? coordinator.create(name: "Work", symbol: "briefcase")
                coordinator.switchTo(Workspace.anonymousID)
                for mode in SidebarMode.allCases {
                    defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
                    snapshot(
                        root(coordinator).defaultAppStorage(defaults),
                        size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                        to: directory.appending(path: "layout-anonymous-\(mode.rawValue)-\(name).png"))
                }
                guard appearance == .aqua else { continue }
                defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
                coordinator.windows[0].workspaceEditor = .rename(Workspace.anonymousID)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-anonymous-sheet.png"))
                coordinator.windows[0].workspaceEditor = nil
            }
        }

        /// A second workspace, created and switched to over Default's sample library: its own empty sidebar shows,
        /// and Default gives up its web views.
        private static func renderWorkspace(to url: URL) {
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            guard (try? coordinator.create(name: "Work", symbol: WorkspaceSymbols.all[1])) != nil else { return }
            snapshot(
                root(coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
                to: url)
            if coordinator.registry.hasViews(on: .global) { print("Default kept its web views after the switch") }
        }

        /// Creates a throwaway workspace with no session or Application Support, shows it, deletes it and prints
        /// whether every step ran: back on Default, nothing pending, no model or web view left on its store.
        /// When the data store cannot be removed, its WebKit store (a fresh UUID each run) stays in the container.
        private static func checkDeletion(to url: URL) {
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            // Its own pool, so the web view this run loop never drains is freed before the data store is removed.
            let made: Workspace? = autoreleasepool {
                guard let doomed = try? coordinator.create(name: "Doomed", symbol: WorkspaceSymbols.all[1])
                else { return nil }
                snapshot(root(coordinator), size: NSSize(width: 800, height: 500), to: url)
                return doomed
            }
            guard let doomed = made else { return }
            var result: Bool?
            Task { result = await coordinator.delete(doomed.id) }
            while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
            let clean =
                result == true && coordinator.activeWorkspace.id == Workspace.defaultID
                && coordinator.pendingDeletions.isEmpty && coordinator.model(for: doomed.id) == nil
                && !coordinator.registry.hasViews(on: .workspace(doomed.id))
            if clean {
                print("Workspace deletion: ok")
            } else {
                print("Workspace deletion: FAILED, WebKit store \(doomed.id.uuidString) may be left")
            }
        }

        /// Checks Anonymous's stores and privacy in the background, printing ok or FAILED for each: two anonymous
        /// stores keep their cookies apart; leaving Anonymous and coming back keeps a tab's cookie; closing the tab
        /// drops its store; and its pages reach neither the saved session nor the saved downloads. No page loads.
        private static func checkAnonymous() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func wait<T>(_ work: @escaping @MainActor () async -> T) -> T {
                var result: T?
                Task { result = await work() }
                while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                return result!
            }
            func cookie(_ name: String) -> HTTPCookie {
                HTTPCookie(properties: [
                    .domain: "signin.example", .path: "/", .name: name, .value: "1",
                    .expires: Date.now.addingTimeInterval(3600),
                ])!
            }
            func names(in store: WKWebsiteDataStore) async -> Set<String> {
                Set(await store.httpCookieStore.allCookies().map(\.name))
            }

            let registry = WebViewRegistry()
            let first = registry.dataStore(for: .ephemeral(UUID()))
            let second = registry.dataStore(for: .ephemeral(UUID()))
            let apart = wait {
                await first.httpCookieStore.setCookie(cookie("first"))
                await second.httpCookieStore.setCookie(cookie("second"))
                return (await names(in: first), await names(in: second))
            }
            report("Anonymous stores keep cookies apart", apart.0 == ["first"] && apart.1 == ["second"])

            let anonymousStore = StoreRef.ephemeral(UUID())
            let faviconTab = TabID()
            registry.attach(tab: faviconTab, to: anonymousStore)
            let ownSession = registry.faviconSession(for: anonymousStore)
            var dropped: StoreRef?
            registry.storeDropped = { dropped = $0 }
            registry.detach(tab: faviconTab)
            report(
                "Anonymous favicon sessions are per store and dropped with it",
                ownSession !== registry.faviconSession(for: .ephemeral(UUID()))
                    && registry.faviconSession(for: .global) === FaviconLoader.shared
                    && registry.faviconSession(for: .workspace(UUID())) === FaviconLoader.shared
                    && dropped == anonymousStore && registry.faviconSession(for: anonymousStore) !== ownSession)

            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.switchTo(Workspace.anonymousID)
            let pane = firstPane(coordinator)
            let model = pane.model
            guard let tab = pane.selected, case .ephemeral = tab.store,
                let store = coordinator.registry.existingDataStore(for: tab.store)
            else { return report("Anonymous tab has its own store", false) }
            wait { await store.httpCookieStore.setCookie(cookie("kept")) }
            coordinator.switchTo(Workspace.defaultID)
            let deadline = Date.now.addingTimeInterval(5)
            while coordinator.registry.webView(for: tab.id) != nil, Date.now < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            let released = coordinator.registry.webView(for: tab.id) == nil
            coordinator.switchTo(Workspace.anonymousID)
            let back = coordinator.registry.existingDataStore(for: tab.store)
            let kept = back.map { back in wait { await names(in: back) } } ?? []
            report("Anonymous release then reselect keeps the cookie", released && back === store && kept == ["kept"])

            model.close(tab.id)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            report(
                "Anonymous close drops the store",
                coordinator.registry.existingDataStore(for: tab.store) == nil && !coordinator.registry.isHeld(tab.store))

            let secret = "anonymous-secret.example"
            let bookmark = URL(string: "https://kept-bookmark.example/")!
            guard let blank = pane.selected else { return report("Anonymous session leaves no URLs", false) }
            model.update(blank.id) { $0.url = bookmark }
            model.addLink(.bookmarks, from: blank.id)
            pane.openLink(SavedLink(url: URL(string: "https://\(secret)/page")!, title: "Secret"), load: false)
            let downloads = DownloadList(items: [
                DownloadItem(
                    sourceURL: URL(string: "https://\(secret)/file.zip"), fileName: "file.zip", state: .finished,
                    startedAt: .now, store: pane.selected?.store),
            ])
            let session = (try? coordinator.snapshot.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let saved = (try? JSONEncoder().encode(downloads.persistable())).map { String(decoding: $0, as: UTF8.self) }
            report(
                "Anonymous session leaves no URLs",
                !session.isEmpty && !session.contains(secret) && session.contains("kept-bookmark.example")
                    && saved.map { !$0.contains(secret) } == true && model.tabs.tabs.contains { $0.url?.host() == secret })
        }

        /// Checks in the background, printing ok or FAILED, that a private download still running when its anonymous
        /// tab closes leaves no row once it ends and its store is dropped. Downloads a `data:` URL into a temporary
        /// folder, removed afterwards; it does not download unless that folder can be accessed, and a file that lands
        /// anywhere else fails the check; the check does not know where such a file went, so it is not removed.
        /// A failure names each condition that did not hold.
        private static func checkPrivateDownloadRow() {
            let name = "Anonymous download ended after its tab closed leaves no row"
            func report(_ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let files = FileManager.default
            let folder = files.temporaryDirectory.appending(
                path: "LodgeSelfCheck-\(UUID())", directoryHint: .isDirectory)
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            defer {
                try? files.removeItem(at: folder)
                UserDefaults.standard.removePersistentDomain(forName: suiteName)
            }
            var isStale = false
            guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                let bookmark = try? folder.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                let resolved = try? URL(
                    resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                    bookmarkDataIsStale: &isStale),
                let defaults = UserDefaults(suiteName: suiteName)
            else { return report(false) }
            // DownloadManager falls back to ~/Downloads when the folder cannot be accessed: then nothing is downloaded.
            guard resolved.startAccessingSecurityScopedResource() else { return report(false) }
            defer { resolved.stopAccessingSecurityScopedResource() }
            defaults.set(bookmark, forKey: DownloadSettings.folderKey)
            let downloads = DownloadManager(directory: nil, defaults: defaults)
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: downloads)
            coordinator.switchTo(Workspace.anonymousID)
            guard let tab = firstPane(coordinator).selected, case .ephemeral = tab.store else { return report(false) }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = coordinator.registry.dataStore(for: tab.store)
            let view = WKWebView(frame: .zero, configuration: config)
            var started = false
            // Handed to the manager inside WebKit's callback, so it is the delegate before the download can end.
            view.startDownload(using: URLRequest(url: URL(string: "data:text/plain,lodge")!)) { download in
                MainActor.assumeIsolated {
                    downloads.start(download, store: tab.store, site: nil, userInitiated: true, isMainFrame: true)
                    started = true
                }
            }
            var deadline = Date.now.addingTimeInterval(5)
            while !started, Date.now < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
            guard started else { return report(false) }
            // Closed before the download can end: only the download holds the store now.
            coordinator.active.close(tab.id)
            coordinator.registry.detach(tab: tab.id)
            let heldByDownload = coordinator.registry.isHeld(tab.store)
            // The row goes with its store as the download ends, so where the file went is read from the folder.
            func landed() -> Bool {
                (try? files.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?
                    .contains { !$0.hasSuffix(".lodgedownload") } == true
            }
            deadline = Date.now.addingTimeInterval(10)
            while !downloads.hasUnseenEnded || coordinator.registry.isHeld(tab.store) || !landed(), Date.now < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            }
            let inFolder = landed()
            if !inFolder { print("\(name): the test file may have been saved in the Downloads folder") }
            let conditions = [
                ("held by the download after the tab closed", heldByDownload),
                ("download ended", downloads.hasUnseenEnded),
                ("store dropped", !coordinator.registry.isHeld(tab.store)),
                ("no row left", !downloads.list.items.contains { $0.store == tab.store }),
                ("file in the temporary folder", inFolder),
            ]
            let failed = conditions.filter { !$0.1 }.map(\.0)
            if !failed.isEmpty { print("\(name): did not hold: \(failed.joined(separator: ", "))") }
            report(failed.isEmpty)
        }

        /// Draws a custom workspace showing Default's sample pins, then checks in the background, printing ok or FAILED
        /// for each: pinning its tab adds to Default's pins, leaves the tab's link nil and the window where it was;
        /// opening a pin from there switches to Default and opens it; unpinning there removes Default's pin. The pin is
        /// `about:blank`, so no request goes out.
        private static func checkSharedPins(to url: URL) {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            guard let work = try? coordinator.create(name: "Work", symbol: "briefcase") else {
                return report("Custom workspace shows Default's pins", false)
            }
            let pane = firstPane(coordinator)
            let model = pane.model
            snapshot(
                root(coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
                to: url)
            report(
                "Custom workspace shows Default's pins",
                model.sidebar.pins.map(\.title) == LinkLibrary.sample.links(on: .pins).map(\.title)
                    && model.sidebar.pins.allSatisfy { $0.tab == nil } && model.library.links(on: .pins).isEmpty)

            let page = URL(string: "about:blank#pinned")!
            guard let tab = pane.selected else { return report("Pinning in a custom workspace adds to Default", false) }
            model.update(tab.id) { $0.url = page }
            pane.togglePinSelectedTab()
            let defaultPins = coordinator.pins
            report(
                "Pinning in a custom workspace adds to Default",
                defaultPins.count == LinkLibrary.sample.links(on: .pins).count + 1 && defaultPins.last?.url == page
                    && pane.selected?.link == nil && model.library.links(on: .pins).isEmpty
                    && coordinator.activeWorkspace.id == work.id && pane.isSelectedTabPinned
                    && model.sidebar.pins.count == defaultPins.count)

            guard let pin = defaultPins.last else { return report("Opening a pin switches to Default", false) }
            pane.activate(.link(pin))
            let home = firstPane(coordinator)
            report(
                "Opening a pin switches to Default",
                coordinator.activeWorkspace.id == Workspace.defaultID && home.selected?.link == pin.id
                    && model.tabs.tab(forLink: pin.id) == nil)

            model.unpin(pin.id)
            report(
                "Unpinning in a custom workspace removes Default's pin",
                !coordinator.pins.contains { $0.id == pin.id } && home.selected?.link == nil
                    && !model.sidebar.pins.contains { $0.id == .link(pin.id) })
        }

        /// Checks Move and Open in Workspace in the background, printing ok or FAILED for each: Move leaves a selected
        /// tab with the same address in the destination and none in the source; Open keeps the original; a move into
        /// Anonymous gets a new browser of its own; a move from a popup closes only that popup's chain; the destination
        /// tab runs on the destination's store. Pages are `about:blank`, and nothing loads in a background workspace.
        private static func checkMoveTabs() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            guard let work = try? coordinator.create(name: "Work", symbol: "briefcase") else {
                return report("Move puts the tab in the destination", false)
            }
            coordinator.switchTo(Workspace.defaultID)
            let pane = firstPane(coordinator)
            let home = pane.model
            guard let tab = pane.selected, let workModel = coordinator.model(for: work.id) else {
                return report("Move puts the tab in the destination", false)
            }
            let moved = URL(string: "about:blank#moved")!
            home.update(tab.id) { $0.url = moved }
            home.open(url: URL(string: "about:blank#kept")!, from: tab.id)
            let destinations = coordinator.destinations(from: Workspace.defaultID).map(\.id)
            report(
                "Destinations list every other workspace, Anonymous last",
                destinations == [work.id, Workspace.anonymousID])

            report(
                "Move puts the tab in the destination",
                coordinator.move(tab: tab.id, to: work.id) && remembered(coordinator, workModel)?.url == moved
                    && remembered(coordinator, workModel)?.link == nil && workModel.tabs.tabs.count == 1 && home.tabs[tab.id] == nil
                    && coordinator.activeWorkspace.id == Workspace.defaultID)
            report(
                "Moved tab runs on the destination's store",
                remembered(coordinator, workModel)?.store == work.store && work.store != tab.store
                    && remembered(coordinator, workModel)?.isLive == false)

            guard let keep = pane.selected, let keptURL = keep.url else { return report("Open keeps the original", false) }
            report(
                "Open keeps the original",
                coordinator.open(tab: keep.id, in: work.id) && home.tabs[keep.id] != nil
                    && workModel.tabs.tabs.count == 2 && remembered(coordinator, workModel)?.url == keptURL
                    && remembered(coordinator, workModel)?.id != keep.id)
            report("Open in the same workspace is refused", !coordinator.open(tab: keep.id, in: Workspace.defaultID))

            guard let anonymous = coordinator.model(for: Workspace.anonymousID),
                coordinator.move(tab: keep.id, to: Workspace.anonymousID), let arrived = remembered(coordinator, anonymous)
            else { return report("Move into Anonymous gets a new browser", false) }
            let others = [home, workModel, anonymous].flatMap(\.tabs.tabs).filter { $0.id != arrived.id }.map(\.store)
            var isEphemeral = false
            if case .ephemeral = arrived.store { isEphemeral = true }
            report(
                "Move into Anonymous gets a new browser",
                isEphemeral && !others.contains(arrived.store) && anonymous.tabs.tabs.count == 1
                    && arrived.url == keptURL && home.tabs[keep.id] == nil)

            guard let opener = pane.selected,
                home.openPopup(from: opener.id, configuration: WKWebViewConfiguration()) != nil,
                let first = pane.selected,
                home.openPopup(from: first.id, configuration: WKWebViewConfiguration()) != nil,
                let second = pane.selected, second.id != first.id, first.id != opener.id
            else { return report("Move from a popup closes only its chain", false) }
            home.update(first.id) { $0.url = URL(string: "about:blank#popup")! }
            let before = workModel.tabs.tabs.count
            report(
                "Move from a popup closes only its chain",
                coordinator.move(tab: first.id, to: work.id) && home.tabs[opener.id] != nil
                    && home.tabs[first.id] == nil && home.tabs[second.id] == nil
                    && workModel.tabs.tabs.count == before + 1 && remembered(coordinator, workModel)?.url?.fragment == "popup"
                    && remembered(coordinator, workModel)?.store == work.store)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        /// Two browser windows on one coordinator, each in its own off-screen `NSWindow`, checked in the background and
        /// printed ok or FAILED for each: ⌘N's window shows a new blank tab of the active workspace with the prompt
        /// open; each window's web view is in that window and no tab is shown twice, after a switch, a pin opened from
        /// the second window and deleting the workspace both are on; switching moves and closes no tab but the blanks
        /// the windows made; the saved session brings both windows back with their tabs and frames, the frame on a
        /// visible screen; closing a window keeps its tabs. Pages are `about:blank`, so no request goes out.
        private static func checkTwoWindows() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            let first = coordinator.windows[0]
            guard let firstTab = coordinator.selections.shown(in: first.id) else {
                return report("New window shows a new tab of the active workspace", false)
            }
            coordinator.active.update(firstTab) { $0.url = URL(string: "about:blank#one")! }
            coordinator.newWindow()
            let second = coordinator.windows[0]
            let secondTab = coordinator.selections.shown(in: second.id)
            report(
                "New window shows a new tab of the active workspace",
                second !== first && coordinator.windows.count == 2 && secondTab != nil && secondTab != firstTab
                    && secondTab.flatMap { coordinator.active.tabs[$0] }?.url == nil
                    && second.locationPrompt == .newTab && coordinator.selections.shown(in: first.id) == firstTab
                    && coordinator.lastActiveBrowserWindow === second)
            guard let secondTab else { return }
            coordinator.active.update(secondTab) { $0.url = URL(string: "about:blank#two")! }
            second.locationPrompt = nil

            let hosts = [first, second].map { host(root(coordinator, $0), size: NSSize(width: 900, height: 600)) }
            defer { for window in hosts { window.close() } }
            settle(0.5)
            func isPlaced() -> Bool {
                let shown = [first, second].map { coordinator.selections.shown(in: $0.id) }
                return zip([first, second], hosts).allSatisfy { window, host in
                    window.nsWindow === host
                        && coordinator.selections.shown(in: window.id)
                            .flatMap { coordinator.registry.webView(for: $0) }?.window === host
                } && Set(shown.compactMap { $0 }).count == 2
            }
            /// Each window's web view in that window, once SwiftUI has redrawn both (up to 3 s).
            func placed() -> Bool {
                let deadline = Date.now.addingTimeInterval(3)
                while !isPlaced(), Date.now < deadline { settle(0.05) }
                return isPlaced()
            }
            report("Two windows on one workspace show their own tabs", placed())

            let homeTabs = Set(coordinator.active.tabs.tabs.map(\.id))
            // Its own pools, so Work's web views this run loop never drains are freed before its data store is removed.
            let made: Workspace? = autoreleasepool { try? coordinator.create(name: "Work", symbol: "briefcase") }
            guard let work = made, let workModel = coordinator.model(for: work.id)
            else { return report("Switching moves every window", false) }
            settle()
            let home = coordinator.model(for: Workspace.defaultID)
            report(
                "Switching moves every window",
                coordinator.activeWorkspaceID == work.id && placed()
                    && [first, second].allSatisfy {
                        coordinator.selections.shown(in: $0.id).map { workModel.tabs[$0] != nil } == true
                    }
                    && home.map { Set($0.tabs.tabs.map(\.id)) } == homeTabs)

            let pinned = BrowserTab(url: URL(string: "about:blank#pinned")!, title: "Pinned")
            coordinator.pin(from: pinned)
            guard let pin = coordinator.pins.last else { return report("Opening a pin moves every window", false) }
            coordinator.pane(for: second).activate(.link(pin))
            settle()
            let pinTab = coordinator.selections.shown(in: second.id).flatMap { home?.tabs[$0] }
            report(
                "Opening a pin moves every window",
                coordinator.activeWorkspaceID == Workspace.defaultID && placed() && pinTab?.link == pin.id
                    && coordinator.selections.shown(in: first.id) == firstTab
                    && home.map { homeTabs.isSubset(of: Set($0.tabs.tabs.map(\.id))) } == true)

            autoreleasepool { coordinator.switchTo(work.id) }
            settle()
            var deleted: Bool?
            Task { deleted = await coordinator.delete(work.id) }
            let deadline = Date.now.addingTimeInterval(10)
            while deleted == nil, Date.now < deadline { settle(0.05) }
            settle()
            report(
                "Deleting the active workspace moves every window to Default",
                deleted == true && coordinator.activeWorkspaceID == Workspace.defaultID && placed()
                    && coordinator.selections.shown(in: first.id) == firstTab
                    && coordinator.selections.shown(in: second.id) == pinTab?.id)

            let saved = (try? coordinator.snapshot.encoded()).flatMap { try? SessionSnapshot.decode($0) }
            let restored = saved.map {
                WorkspaceCoordinator(restoring: $0, session: nil, appDirectory: nil, downloads: nil)
            }
            let expectedFrames = [second, first].map { $0.nsWindow.map { SessionSnapshot.WindowFrame($0.frame) } }
            let restoredTabs = restored.map { restored in
                restored.windows.map { restored.selections.shown(in: $0.id) }
            }
            var onScreen = false
            if let restored, restored.windows.count == 2 {
                let window = restored.windows[0]
                let restoredHost = host(root(restored, window), size: NSSize(width: 900, height: 600))
                settle()
                let frame = restoredHost.frame
                onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(frame) }
                restoredHost.close()
            }
            report(
                "Relaunch restores each window's tab and frame",
                saved?.windows.map(\.frame) == expectedFrames && expectedFrames.allSatisfy { $0 != nil }
                    && restoredTabs == [pinTab?.id, firstTab]
                    && (NSScreen.screens.isEmpty || onScreen))

            hosts[1].close()
            settle()
            report(
                "Closing a window keeps its tabs",
                coordinator.windows.count == 1 && coordinator.windows[0] === first
                    && coordinator.lastActiveBrowserWindow === first && pinTab.map { home?.tabs[$0.id] != nil } == true
                    && coordinator.snapshot.windows.count == 1)
        }

        /// Two windows on Default's sample library, checked in the background and printed ok or FAILED for each: from
        /// the second window, a sidebar click, a bookmark open, a History entry and a pin open on the tab the first
        /// window shows each ask to bring the first window forward (a hook stands in, so nothing activates), leave
        /// both windows' tabs as they were and open no second tab; the second window marks that tab and the first
        /// does not. Draws the second window's sidebar with a marked bookmark row, then a marked pin, in light and
        /// dark. Nothing loads: tabs open unloaded and the History URL is on `.invalid`.
        private static func checkShownElsewhere(in directory: URL) {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            let first = coordinator.windows[0]
            let model = coordinator.active
            guard let bookmark = model.library.links(on: .bookmarks).first, let pin = model.library.links(on: .pins).first
            else { return report("Sidebar click on another window's tab brings it forward", false) }
            coordinator.pane(for: first).openLink(bookmark, load: false)
            guard let shown = coordinator.selections.shown(in: first.id) else {
                return report("Sidebar click on another window's tab brings it forward", false)
            }
            let page = URL(string: "https://lodge.invalid/shown")!
            model.update(shown) { $0.url = page }
            coordinator.newWindow()
            let second = coordinator.windows[0]
            second.locationPrompt = nil
            var asked: [WindowState] = []
            coordinator.bringForwardHook = { asked.append($0) }

            /// Runs `action` from the second window: true when it asked for the first window alone and changed no
            /// window's tab and no tab count.
            func bringsFirstForward(_ action: (BrowserPane) -> Void) -> Bool {
                let before = [first, second].map { coordinator.selections.shown(in: $0.id) }
                let count = model.tabs.tabs.count
                asked = []
                action(coordinator.pane(for: second))
                return asked.count == 1 && asked[0] === first && model.tabs.tabs.count == count
                    && [first, second].map { coordinator.selections.shown(in: $0.id) } == before
            }

            let otherPane = coordinator.pane(for: second)
            report(
                "Only the other window marks the tab",
                otherPane.isShownElsewhere(shown) && !coordinator.pane(for: first).isShownElsewhere(shown)
                    && otherPane.selectedID.map(otherPane.isShownElsewhere) == false)
            report("Sidebar click on another window's tab brings it forward", bringsFirstForward { $0.select(shown) })
            report(
                "Opening a bookmark another window shows brings it forward",
                bringsFirstForward { $0.activate(.link(bookmark)) })
            report(
                "A History entry another window shows brings it forward",
                bringsFirstForward { $0.open(historyURL: page) })
            renderShownElsewhere(coordinator, second, defaults: defaults, in: directory, name: "shown-elsewhere")

            coordinator.pane(for: first).openLink(pin, load: false)
            report(
                "Opening a pin another window shows brings it forward",
                coordinator.selections.shown(in: first.id).flatMap { model.tabs[$0] }?.link == pin.id
                    && bringsFirstForward { $0.activate(.link(pin)) })
            renderShownElsewhere(coordinator, second, defaults: defaults, in: directory, name: "shown-elsewhere-pin")
        }

        private static func renderShownElsewhere(
            _ coordinator: WorkspaceCoordinator, _ window: WindowState, defaults: UserDefaults, in directory: URL,
            name: String
        ) {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                snapshot(
                    root(coordinator, window).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
                    appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }

        /// Stepping through tabs in a second window passes over the tab the first window shows, printed ok or FAILED:
        /// with three tabs it lands on the third and brings no window forward; with only the two shown tabs it stays
        /// put. Pages are `about:blank` and never load.
        private static func checkStepSkipsShownElsewhere() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            let first = coordinator.windows[0]
            let model = coordinator.active
            guard let shown = coordinator.selections.shown(in: first.id) else {
                return report("Stepping passes over another window's tab", false)
            }
            model.update(shown) { $0.url = URL(string: "about:blank#one")! }
            coordinator.newWindow()
            let second = coordinator.windows[0]
            second.locationPrompt = nil
            guard let own = coordinator.selections.shown(in: second.id) else {
                return report("Stepping passes over another window's tab", false)
            }
            var asked = 0
            coordinator.bringForwardHook = { _ in asked += 1 }

            let lone = coordinator.pane(for: second)
            lone.selectNextTab()
            lone.selectPreviousTab()
            report(
                "Stepping with only another window's tab stays put",
                asked == 0 && coordinator.selections.shown(in: second.id) == own
                    && coordinator.selections.shown(in: first.id) == shown)

            let third = BrowserTab(url: URL(string: "about:blank#three")!, title: "Three")
            _ = model.append(third, load: false)
            // The direction whose next entry is the first window's tab, so the step has to pass over it.
            let offset = model.sidebar.target(1, from: own) == .tab(shown) ? 1 : -1
            let pane = coordinator.pane(for: second)
            if offset == 1 { pane.selectNextTab() } else { pane.selectPreviousTab() }
            report(
                "Stepping passes over another window's tab",
                model.sidebar.target(offset, from: own) == .tab(shown) && asked == 0
                    && coordinator.selections.shown(in: second.id) == third.id
                    && coordinator.selections.shown(in: first.id) == shown)
        }

        /// Links from other apps (D7), printed ok or FAILED for each: a link arriving before the restored window is on
        /// screen waits, then loads into that window's blank tab once it registers; from Anonymous a link still opens
        /// in Default; with two windows on a custom workspace every window moves to Default, the link opens once, as
        /// a new tab shown in the last active window, and all windows are brought forward. Bringing forward is a hook
        /// here, so the app is never activated. Pages are `about:blank`, so no request goes out.
        private static func checkExternalLinks() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            /// WebKit reports an `about:blank#x` page back as `about:blank%23x`, so the address is compared decoded.
            func tabs(_ coordinator: WorkspaceCoordinator, with url: URL) -> [BrowserTab] {
                let wanted = url.absoluteString.removingPercentEncoding
                return coordinator.model(for: Workspace.defaultID)?.tabs.tabs.filter {
                    $0.url?.absoluteString.removingPercentEncoding == wanted
                } ?? []
            }

            let cold = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            var coldForward = 0
            cold.bringAllForwardOverride = { coldForward += 1 }
            let window = cold.windows[0]
            let blank = cold.selections.shown(in: window.id)
            let queued = URL(string: "about:blank#queued")!
            cold.openExternal([queued])
            cold.openRestoredWindows()
            settle(0.1)
            let waited = tabs(cold, with: queued).isEmpty && coldForward == 0
            let coldHost = host(root(cold, window), size: NSSize(width: 900, height: 600))
            defer { coldHost.close() }
            let deadline = Date.now.addingTimeInterval(3)
            while tabs(cold, with: queued).isEmpty, Date.now < deadline { settle(0.05) }
            let opened = tabs(cold, with: queued)
            report(
                "A link before the windows are restored waits, then opens",
                waited && window.nsWindow === coldHost && opened.count == 1 && opened.first?.id == blank
                    && cold.selections.shown(in: window.id) == blank && cold.active.tabs.tabs.count == 1
                    && coldForward == 1)

            cold.switchTo(Workspace.anonymousID)
            let fromAnonymous = URL(string: "about:blank#anonymous")!
            cold.openExternal([fromAnonymous])
            let shown = cold.selections.shown(in: window.id)
            report(
                "A link from Anonymous opens in Default",
                cold.activeWorkspaceID == Workspace.defaultID && tabs(cold, with: fromAnonymous).count == 1
                    && shown == tabs(cold, with: fromAnonymous).first?.id && coldForward == 2)

            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            var forward = 0
            coordinator.bringAllForwardOverride = { forward += 1 }
            let first = coordinator.windows[0]
            if let home = coordinator.selections.shown(in: first.id) {
                coordinator.active.update(home) { $0.url = URL(string: "about:blank#home")! }
            }
            coordinator.openRestoredWindows()
            let second = coordinator.newWindow()
            second.locationPrompt = nil
            let hosts = [first, second].map { host(root(coordinator, $0), size: NSSize(width: 900, height: 600)) }
            defer { for host in hosts { host.close() } }
            settle(0.5)
            let made: Workspace? = autoreleasepool { try? coordinator.create(name: "Work", symbol: "briefcase") }
            guard let work = made else { return report("A link moves every window to Default", false) }
            settle()
            let before = coordinator.model(for: Workspace.defaultID)?.tabs.tabs.map(\.id) ?? []
            let link = URL(string: "about:blank#link")!
            let last = coordinator.lastActiveBrowserWindow
            coordinator.openExternal([link])
            settle()
            let linkTabs = tabs(coordinator, with: link)
            let after = coordinator.model(for: Workspace.defaultID)?.tabs.tabs.map(\.id) ?? []
            report(
                "A link moves every window to Default",
                coordinator.activeWorkspaceID == Workspace.defaultID && work.id != Workspace.defaultID
                    && [first, second].allSatisfy {
                        coordinator.selections.shown(in: $0.id)
                            .map { coordinator.model(for: Workspace.defaultID)?.tabs[$0] != nil } == true
                    })
            report(
                "A link opens one new tab in the last active window, all windows forward",
                linkTabs.count == 1 && !before.contains(linkTabs[0].id) && after.contains(linkTabs[0].id)
                    && last.map { coordinator.selections.shown(in: $0.id) } == linkTabs[0].id && forward == 1)
            settle()
        }

        /// Lodge pages (D1, C5), printed ok or FAILED for each: a link click, a cmd-click, `window.open`, a redirect
        /// and an iframe to `lodge://settings` from a web page are refused and open no tab; typed, prompt, pin,
        /// bookmark and received opens of a page land on its one tab; a Lodge tab never gets a web view, and none
        /// slips under a web tab's view; loading a web address in a Lodge tab drops its link. Pages are inline HTML
        /// and `about:blank`, so no request goes out; bringing forward is a hook, so nothing activates.
        private static func checkLodgePages() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.bringForwardHook = { _ in }
            let window = coordinator.windows[0]
            window.locationPrompt = nil
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            let pane = coordinator.pane(for: window)
            let model = pane.model
            func pages(_ page: LodgePage, in model: BrowserModel) -> [BrowserTab] {
                model.tabs.tabs.filter { $0.lodgePage == page }
            }

            let blank = pane.selectedID
            pane.load("lodge://settings")
            guard let settings = model.tab(showing: .settings) else { return report("A typed Lodge address opens", false) }
            report(
                "A typed Lodge address opens its page in place of the blank tab",
                model.tabs.tabs.map(\.id) == [settings.id] && pane.selectedID == settings.id && blank != settings.id
                    && settings.url == LodgePage.settings.url)

            window.locationPrompt = .newTab
            pane.submitLocation("about:blank")
            guard let web = pane.selected, web.id != settings.id, let view = model.view(for: web.id, load: false) else {
                return report("A web page cannot reach a Lodge page", false)
            }
            let vectors = [
                ("A link click to lodge:// is refused", "<a id=a href='lodge://settings'>x</a>", "document.getElementById('a').click()"),
                (
                    "A cmd-click to lodge:// is refused", "<a id=a href='lodge://settings'>x</a>",
                    "document.getElementById('a').dispatchEvent(new MouseEvent('click', {metaKey: true, bubbles: true, cancelable: true}))"
                ),
                ("window.open of lodge:// is refused", "<p>x</p>", "window.open('lodge://settings')"),
                ("A redirect to lodge:// is refused", "<p>x</p>", "location.replace('lodge://settings')"),
                ("An iframe of lodge:// is refused", "<p>x</p>", "document.body.appendChild(Object.assign(document.createElement('iframe'), {src: 'lodge://settings'}))"),
            ]
            for (index, (name, html, script)) in vectors.enumerated() {
                let marker = "vector-\(index)"
                view.loadHTMLString("<!doctype html><title>\(marker)</title><body>\(html)</body>", baseURL: nil)
                let deadline = Date.now.addingTimeInterval(5)
                while view.title != marker || view.isLoading, Date.now < deadline { settle(0.05) }
                let count = model.tabs.tabs.count
                let refusals = TabController.lodgeRefusals
                view.evaluateJavaScript(script)
                settle(0.5)
                report(
                    name,
                    TabController.lodgeRefusals > refusals && model.tabs.tabs.count == count
                        && pages(.settings, in: model).map(\.id) == [settings.id]
                        && !LodgePage.isLodge(model.tabs[web.id]?.url) && model.registry.webView(for: web.id) === view)
            }

            let webURL = model.tabs[web.id]?.url
            pane.load("LODGE://SETTINGS")
            let typedAgain = pane.selectedID == settings.id && model.tabs[web.id]?.url == webURL
                && model.registry.webView(for: web.id) === view
            pane.select(web.id)
            window.locationPrompt = .current(web.id)
            pane.submitLocation("lodge://settings/")
            let prompted = pane.selectedID == settings.id && model.tabs[web.id]?.url == webURL
            let pin = model.addPin(LodgePage.settings.url, title: "Settings")
            pane.select(web.id)
            pane.openLink(pin, load: false)
            let pinned = pane.selectedID == settings.id
            model.update(web.id) { $0.url = LodgePage.history.url }
            let guarded = model.tabs[web.id]?.url == webURL
            report(
                "Typed, prompt and pin opens of a page select its one tab",
                typedAgain && prompted && pinned && pages(.settings, in: model).count == 1)
            report("A web tab's address never turns into a Lodge page", guarded && model.tab(showing: .history) == nil)

            pane.open(.history)
            guard let marked = model.tab(showing: .history) else { return report("Bookmark opens select one tab", false) }
            model.addLink(.bookmarks, from: marked.id)
            guard let bookmark = model.library.links(on: .bookmarks).first(where: { $0.url == LodgePage.history.url })
            else { return report("Bookmark opens select one tab", false) }
            model.close(marked.id)
            pane.openLink(bookmark, load: false)
            pane.openLink(bookmark, load: false)
            pane.load("lodge://history")
            coordinator.open(.history)
            guard let history = model.tab(showing: .history) else { return report("Bookmark opens select one tab", false) }
            report(
                "Bookmark and menu opens of a page select its one tab",
                pages(.history, in: model).count == 1 && history.link == bookmark.id && pane.selectedID == history.id)

            let made: Workspace? = try? coordinator.create(name: "Work", symbol: "briefcase")
            coordinator.switchTo(Workspace.defaultID)
            guard let work = made, let workModel = coordinator.model(for: work.id) else {
                return report("Received pages dedupe to one tab", false)
            }
            let first = coordinator.open(tab: settings.id, in: work.id)
            let second = coordinator.open(tab: settings.id, in: work.id)
            report(
                "Received pages dedupe to one tab",
                first && second && pages(.settings, in: workModel).count == 1
                    && model.receive(url: LodgePage.settings.url, title: "") == settings.id
                    && pages(.settings, in: model).count == 1)

            let lodgeTabs = (model.tabs.tabs + workModel.tabs.tabs).filter { LodgePage.isLodge($0.url) }
            for owner in [model, workModel] {
                for tab in owner.tabs.tabs where LodgePage.isLodge(tab.url) { owner.view(for: tab.id) }
            }
            pane.select(settings.id)
            settle()
            report(
                "A Lodge tab never gets a web view",
                lodgeTabs.count == 3
                    && lodgeTabs.allSatisfy { coordinator.registry.webView(for: $0.id) == nil && !$0.isLive }
                    && model.tabs[settings.id]?.isLive == false)

            pane.select(history.id)
            window.locationPrompt = .current(history.id)
            pane.submitLocation("about:blank#left")
            settle()
            let left = model.tabs[history.id]
            report(
                "Loading a web address in a Lodge tab drops its link",
                left?.link == nil && left?.lodgePage == nil && left?.canGoBack == false
                    && model.registry.webView(for: history.id) != nil && pane.selectedID == history.id)
            pane.openLink(bookmark, load: false)
            report(
                "Its bookmark still opens the Lodge page",
                model.tab(showing: .history).map { $0.id != history.id && $0.link == bookmark.id } == true)
            settle()
        }

        /// Checks in the background, printing ok or FAILED, that unsent work keeps a hidden workspace's tab: text
        /// inserted into a field of an offscreen page (`insertText`, no keyboard) keeps the tab's web view when its
        /// workspace is left, and the page sending the form, or emptying the field, lets it go at once. A form posted
        /// into a new window does not hold its opener. A page whose `beforeunload` handler cancels is kept (best
        /// effort) and asked only once however often the release is retried within the re-ask interval, then released
        /// on a retry after it once the handler is gone; one whose handler stalls is released
        /// after the probe's deadline. The pages are HTML strings, so no request goes out.
        private static func checkWorkHolds() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !done(), Date.now < deadline { settle(0.05) }
                return done()
            }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.bringForwardHook = { _ in }
            let window = coordinator.windows[0]
            window.locationPrompt = .newTab
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            let pane = coordinator.pane(for: window)
            let model = pane.model
            pane.submitLocation("about:blank")
            guard let tab = pane.selected, let made = try? coordinator.create(name: "Work", symbol: "briefcase") else {
                return report("Typed text keeps a hidden workspace's tab", false)
            }
            /// Shows the tab on a fresh page, with "draft" typed into its field `f` when `typing`.
            func show(_ name: String, _ body: String, typing: Bool = false) -> LodgeWebView? {
                coordinator.switchTo(Workspace.defaultID)
                coordinator.pane(for: window).select(tab.id)
                guard let view = model.view(for: tab.id, load: false) else { return nil }
                view.loadHTMLString("<!doctype html><title>\(name)</title><body>\(body)</body>", baseURL: nil)
                guard waitUntil({ view.title == name && !view.isLoading }) else { return nil }
                settle()
                if typing {
                    hostWindow.makeFirstResponder(view)
                    view.evaluateJavaScript("document.getElementById('f').focus()")
                    settle()
                    view.insertText("draft")
                    guard waitUntil({ model.hasUnsentWork(tab.id) }) else { return nil }
                }
                return view
            }
            /// Leaves the workspace and says whether the view is still there a moment later.
            func keptAfterLeaving(_ view: LodgeWebView) -> Bool {
                coordinator.switchTo(made.id)
                settle(1.5)
                return coordinator.registry.webView(for: tab.id) === view
            }
            func pageValue(_ view: LodgeWebView, _ script: String) -> Any? {
                var answer: Any?
                var done = false
                view.evaluateJavaScript(script) { value, _ in
                    answer = value
                    done = true
                }
                _ = waitUntil { done }
                return answer
            }

            let form = "<form id=form onsubmit='return false'><input id=f></form>"
            let endings = [
                ("Typed text keeps a hidden workspace's tab until the form is sent", "form.requestSubmit()"),
                (
                    "Typed text keeps a hidden workspace's tab until the field is emptied",
                    "f.value = ''; f.dispatchEvent(new Event('input', {bubbles: true}))"
                ),
            ]
            for (index, (name, ending)) in endings.enumerated() {
                guard let view = show("work-\(index)", form, typing: true), keptAfterLeaving(view) else {
                    report(name, false)
                    continue
                }
                view.evaluateJavaScript(ending)
                report(name, waitUntil { coordinator.registry.webView(for: tab.id) == nil })
            }

            let blankForm = "<form id=form method=post target=_blank action='about:blank'><input name=q value=x></form>"
            let before = Set(model.tabs.tabs.map(\.id))
            if let view = show("blank-form", blankForm) {
                view.evaluateJavaScript("form.requestSubmit()")
                let opened = waitUntil { model.tabs.tabs.count > before.count }
                settle(0.5)
                report("A form posted into a new window does not hold its opener", opened && !model.hasUnsentWork(tab.id))
                for popup in model.tabs.tabs where !before.contains(popup.id) { model.close(popup.id) }
                settle()
            } else {
                report("A form posted into a new window does not hold its opener", false)
            }

            let asks = """
                <script>
                window.probes = 0;
                window.onbeforeunload = (e) => { window.probes += 1; e.preventDefault(); return 'leave?'; };
                </script>
                """
            if let view = show("asks", asks), keptAfterLeaving(view) {
                for _ in 0..<3 {
                    model.holdStateChanged(tab.id)
                    settle(0.5)
                }
                let probes = pageValue(view, "window.probes") as? Int
                report(
                    "A page that asks before leaving keeps a hidden workspace's tab, asked once",
                    coordinator.registry.webView(for: tab.id) === view && probes == 1 && !model.hasUnsentWork(tab.id))
                // The editor saved and dropped its handler: once the (shortened) re-ask interval passes, a retry
                // asks again and lets the tab go.
                let reprobe = BrowserModel.beforeUnloadReprobe
                BrowserModel.beforeUnloadReprobe = .milliseconds(300)
                defer { BrowserModel.beforeUnloadReprobe = reprobe }
                view.evaluateJavaScript("window.onbeforeunload = null")
                settle(0.4)
                model.holdStateChanged(tab.id)
                report(
                    "A page that stops asking is released on a later retry",
                    waitUntil { coordinator.registry.webView(for: tab.id) == nil })
            } else {
                report("A page that asks before leaving keeps a hidden workspace's tab, asked once", false)
            }

            let stalls = "<script>window.onbeforeunload = () => { const end = Date.now() + 3000; while (Date.now() < end) {} };</script>"
            if let view = show("stalls", stalls) {
                report("A page whose beforeunload stalls is released after the deadline", !keptAfterLeaving(view))
            } else {
                report("A page whose beforeunload stalls is released after the deadline", false)
            }
            coordinator.switchTo(Workspace.defaultID)
            model.close(tab.id)
            settle()
        }

        /// Resting (#23), with the rest time shortened to a fraction of a second: a background tab of the shown
        /// workspace rests and shows as resting, while the selected tab and a background tab with typed text stay;
        /// selecting the rested tab builds its page again from its kept state. The pages are `data:` URLs, so no
        /// request goes out.
        private static func checkResting() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !done(), Date.now < deadline { settle(0.05) }
                return done()
            }
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, restDefaults: nil)
            coordinator.bringForwardHook = { _ in }
            let window = coordinator.windows[0]
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            let pane = coordinator.pane(for: window)
            let model = pane.model
            /// Opens a new tab showing `body`, titled `name`.
            func open(_ name: String, _ body: String) -> (TabID, LodgeWebView)? {
                window.locationPrompt = .newTab
                pane.submitLocation("about:blank")
                let html = "<!doctype html><title>\(name)</title><body>\(body)</body>"
                guard let id = pane.selectedID,
                    let page = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                        .flatMap({ URL(string: "data:text/html,\($0)") }),
                    model.load(page, in: id), let view = coordinator.registry.webView(for: id)
                else { return nil }
                guard waitUntil({ view.title == name && !view.isLoading }) else { return nil }
                settle()
                return (id, view)
            }
            guard let (resting, _) = open("rest-plain", "<p>plain</p>"),
                let (typed, typedView) = open("rest-typed", "<input id=f>")
            else { return report("A background tab rests after the rest time", false) }
            hostWindow.makeFirstResponder(typedView)
            typedView.evaluateJavaScript("document.getElementById('f').focus()")
            settle()
            typedView.insertText("draft")
            guard waitUntil({ model.hasUnsentWork(typed) }), let (shown, shownView) = open("rest-shown", "<p>shown</p>")
            else { return report("A background tab rests after the rest time", false) }

            coordinator.restIntervalOverride = .milliseconds(300)
            defer { coordinator.restIntervalOverride = nil }
            let rested = waitUntil { coordinator.registry.webView(for: resting) == nil }
            report(
                "A background tab rests after the rest time and shows as resting",
                rested && model.tabs[resting]?.isResting == true)
            settle(1)
            report(
                "The selected tab stays awake past the rest time",
                coordinator.registry.webView(for: shown) === shownView && model.tabs[shown]?.isResting == false)
            report(
                "A background tab with typed text stays awake past the rest time",
                coordinator.registry.webView(for: typed) === typedView && model.tabs[typed]?.isResting == false)

            pane.select(resting)
            let woke = waitUntil {
                coordinator.registry.webView(for: resting)?.title == "rest-plain" && model.tabs[resting]?.isLive == true
            }
            report("Selecting a resting tab builds its page again", woke && model.tabs[resting]?.isResting == false)
            for id in [resting, typed, shown] { model.close(id) }
            settle()
        }

        /// Memory pressure (#25), with `relieve` called directly, never by using memory: a warning rests an unshown,
        /// unheld tab of the shown workspace and of a background workspace that keeps a tab with typed text, and keeps
        /// the selected tab and both tabs with typed text; critical then keeps the Anonymous store a resting tab holds
        /// and the one a download holds. The pages are `data:` URLs, so no request goes out.
        private static func checkMemoryPressure() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !done(), Date.now < deadline { settle(0.05) }
                return done()
            }
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, restDefaults: nil)
            coordinator.bringForwardHook = { _ in }
            coordinator.restAfter = .never
            let registry = coordinator.registry
            let window = coordinator.windows[0]
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            func relieve(_ level: MemoryPressureLevel) {
                var done = false
                Task {
                    await coordinator.relieve(level)
                    done = true
                }
                _ = waitUntil { done }
            }
            /// Opens a new tab in the shown workspace showing `body`, titled `name`, with "draft" typed into its field
            /// `f` when `typing`.
            func open(_ name: String, _ body: String, typing: Bool = false) -> (TabID, LodgeWebView)? {
                let pane = coordinator.pane(for: window)
                window.locationPrompt = .newTab
                pane.submitLocation("about:blank")
                let html = "<!doctype html><title>\(name)</title><body>\(body)</body>"
                guard let id = pane.selectedID,
                    let page = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                        .flatMap({ URL(string: "data:text/html,\($0)") }),
                    pane.model.load(page, in: id), let view = registry.webView(for: id)
                else { return nil }
                guard waitUntil({ view.title == name && !view.isLoading }) else { return nil }
                settle()
                if typing {
                    hostWindow.makeFirstResponder(view)
                    view.evaluateJavaScript("document.getElementById('f').focus()")
                    settle()
                    view.insertText("draft")
                    guard waitUntil({ pane.model.hasUnsentWork(id) }) else { return nil }
                }
                return (id, view)
            }
            let failed = "Low memory rests an unshown tab of the shown and of a background workspace"
            coordinator.switchTo(Workspace.anonymousID)
            guard let (anonymous, _) = open("pressure-anonymous", "<p>anonymous</p>"),
                let anonymousStore = coordinator.active.tabs[anonymous]?.store,
                let made = try? coordinator.create(name: "Pressure", symbol: "briefcase")
            else { return report(failed, false) }
            coordinator.switchTo(made.id)
            let work = coordinator.active
            guard let (backgroundPlain, _) = open("pressure-bg-plain", "<p>plain</p>"),
                let (backgroundTyped, backgroundTypedView) = open("pressure-bg-typed", "<input id=f>", typing: true)
            else { return report(failed, false) }
            coordinator.switchTo(Workspace.defaultID)
            let model = coordinator.active
            let leftBehind = [backgroundPlain, anonymous]
            guard waitUntil({ leftBehind.allSatisfy { registry.webView(for: $0) == nil } }),
                let (plain, _) = open("pressure-plain", "<p>plain</p>"),
                let (typed, typedView) = open("pressure-typed", "<input id=f>", typing: true),
                let (shown, shownView) = open("pressure-shown", "<p>shown</p>")
            else { return report(failed, false) }
            // Built again while its workspace is hidden, it stands in for a tab the leave pass has not reached; the
            // held tab's retry is 30 s off, so only `relieve` can let it go.
            guard work.view(for: backgroundPlain) != nil, registry.webView(for: backgroundTyped) === backgroundTypedView
            else { return report(failed, false) }
            settle()

            relieve(.warning)
            report(
                failed,
                registry.webView(for: plain) == nil && registry.webView(for: backgroundPlain) == nil
                    && model.tabs[plain]?.isResting == true)
            report("Low memory keeps the selected tab", registry.webView(for: shown) === shownView)
            report(
                "Low memory keeps tabs with typed text, shown workspace and background",
                registry.webView(for: typed) === typedView
                    && registry.webView(for: backgroundTyped) === backgroundTypedView)

            let download = UUID()
            let downloadStore = StoreRef.ephemeral(UUID())
            _ = registry.dataStore(for: downloadStore)
            registry.hold(download: download, on: downloadStore)
            // An Anonymous bookmark's stored icon, decoded once before the pressure and again after it.
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            let bookmark = SavedLink(
                url: URL(string: "https://pressure.example/")!, title: "Pressure",
                icon: bitmap?.representation(using: .png, properties: [:]))
            let item = SidebarItem.link(bookmark, .bookmarks, nil)
            let anonymousModel = coordinator.model(for: Workspace.anonymousID)
            let iconBefore = anonymousModel?.favicon(for: item)
            relieve(.critical)
            let iconAfter = anonymousModel?.favicon(for: item)
            report(
                "Critical low memory drops a decoded bookmark icon and the sidebar decodes it again",
                iconBefore != nil && iconAfter != nil && iconAfter !== iconBefore
                    && anonymousModel?.favicon(for: item) === iconAfter)
            report(
                "Critical low memory keeps Anonymous stores a resting tab or a download holds",
                registry.existingDataStore(for: anonymousStore) != nil
                    && registry.existingDataStore(for: downloadStore) != nil)
            report(
                "Critical low memory still keeps the selected tab and tabs with typed text",
                registry.webView(for: shown) === shownView && registry.webView(for: typed) === typedView
                    && registry.webView(for: backgroundTyped) === backgroundTypedView)
            report(
                "Nothing wakes after low memory",
                registry.webView(for: plain) == nil && registry.webView(for: backgroundPlain) == nil)
            registry.releaseHold(download: download)
            for id in [plain, typed, shown] { model.close(id) }
            settle()
        }

        /// Critical memory pressure (#25) keeps a hidden custom workspace's data store, though all its tabs rest:
        /// WebKit keeps a store's session cookies (no expiry, in memory only) only while the store object lives, so
        /// dropping it would sign the user out. A session cookie set on that store is still there after `relieve`
        /// and after a tab wakes. The cookie is set directly and the page is a `data:` URL, so no request goes out.
        private static func checkPressureKeepsSessionStore() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !done(), Date.now < deadline { settle(0.05) }
                return done()
            }
            func wait<T>(_ work: @escaping @MainActor () async -> T) -> T? {
                var result: T?
                Task { result = await work() }
                _ = waitUntil { result != nil }
                return result
            }
            let domain = "pressure-cookies.example"
            func names(in store: WKWebsiteDataStore) async -> Set<String> {
                Set(await store.httpCookieStore.allCookies().filter { $0.domain.contains(domain) }.map(\.name))
            }
            let name = "Critical low memory keeps a hidden workspace's store and its session cookie"
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, restDefaults: nil)
            coordinator.bringForwardHook = { _ in }
            coordinator.restAfter = .never
            let registry = coordinator.registry
            let window = coordinator.windows[0]
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            guard let made = try? coordinator.create(name: "Pressure Cookies", symbol: "briefcase"),
                let store = made.store
            else { return report(name, false) }
            coordinator.switchTo(made.id)
            let pane = coordinator.pane(for: window)
            window.locationPrompt = .newTab
            pane.submitLocation("about:blank")
            let html = "<!doctype html><title>pressure-cookie</title><p>cookie</p>"
            guard let tab = pane.selectedID,
                let page = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                    .flatMap({ URL(string: "data:text/html,\($0)") }),
                pane.model.load(page, in: tab),
                waitUntil({
                    registry.webView(for: tab).map { $0.title == "pressure-cookie" && !$0.isLoading } == true
                }),
                let first = registry.existingDataStore(for: store)
            else { return report(name, false) }
            let session = HTTPCookie(properties: [.domain: domain, .path: "/", .name: "pressure-session", .value: "1"])!
            guard wait({ await first.httpCookieStore.setCookie(session) }) != nil else { return report(name, false) }

            coordinator.switchTo(Workspace.defaultID)
            guard waitUntil({ !registry.hasViews(on: store) }) else { return report(name, false) }
            var done = false
            Task {
                await coordinator.relieve(.critical)
                done = true
            }
            _ = waitUntil { done }
            report(name, registry.existingDataStore(for: store) === first)

            coordinator.switchTo(made.id)
            let woke = waitUntil { registry.webView(for: tab)?.title == "pressure-cookie" }
            report(
                "A tab woken after critical low memory still has its session cookie",
                woke && registry.webView(for: tab)?.configuration.websiteDataStore === first
                    && wait({ await names(in: first) }) == ["pressure-session"])
            _ = wait { await first.httpCookieStore.deleteCookie(session) }
            coordinator.switchTo(Workspace.defaultID)
            settle()
        }

        /// A released web view and the data store of a closed Anonymous tab are freed, not only dropped from the
        /// registry: a tab left by a workspace switch and a tab resting under low memory each let their `LodgeWebView`
        /// go, and closing the last Anonymous tab lets its store go. They are watched only through `weak` references.
        /// This runs before `NSApplication.run`, so no event loop drains the outermost autorelease pool: every step
        /// runs in a pool of its own, as each event does in the app, or an autoreleased reference would keep the
        /// view alive until exit. The left custom workspace's store stays cached on purpose: WebKit keeps a store's
        /// session cookies only while the store object lives.
        private static func checkReleasedViewGoes() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !autoreleasepool(invoking: done), Date.now < deadline { settle(0.05) }
                return autoreleasepool(invoking: done)
            }
            final class Watch<Object: AnyObject> {
                weak var object: Object?
                var isGone: Bool { object == nil }
            }
            let left = Watch<LodgeWebView>()
            let rested = Watch<LodgeWebView>()
            let anonymousStore = Watch<WKWebsiteDataStore>()
            let switchName = "A tab left by a workspace switch frees its web view"
            let restName = "A tab resting under low memory frees its web view"
            let anonymousName = "Closing the last Anonymous tab frees its data store"
            let coordinator = autoreleasepool {
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, restDefaults: nil)
                coordinator.bringForwardHook = { _ in }
                coordinator.restAfter = .never
                return coordinator
            }
            let registry = coordinator.registry
            let window = coordinator.windows[0]
            let hostWindow = autoreleasepool { host(root(coordinator, window), size: NSSize(width: 900, height: 600)) }
            defer { hostWindow.close() }
            /// Opens a new tab in the shown workspace titled `name`, its view watched by `watch`.
            func open(_ name: String, into watch: Watch<LodgeWebView> = Watch()) -> TabID? {
                let id: TabID? = autoreleasepool {
                    let pane = coordinator.pane(for: window)
                    window.locationPrompt = .newTab
                    pane.submitLocation("about:blank")
                    let html = "<!doctype html><title>\(name)</title><p>\(name)</p>"
                    guard let id = pane.selectedID,
                        let page = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                            .flatMap({ URL(string: "data:text/html,\($0)") }),
                        pane.model.load(page, in: id)
                    else { return nil }
                    watch.object = registry.webView(for: id)
                    return id
                }
                guard let id, waitUntil({ watch.object.map { $0.title == name && !$0.isLoading } == true }) else {
                    return nil
                }
                return id
            }

            let made = autoreleasepool { try? coordinator.create(name: "Released", symbol: "briefcase") }
            guard let made, let store = made.store, open("released-left", into: left) != nil,
                open("released-left-shown") != nil
            else { return report(switchName, false) }
            let leftStore = autoreleasepool { registry.existingDataStore(for: store) }
            autoreleasepool { coordinator.switchTo(Workspace.defaultID) }
            report(switchName, waitUntil { left.isGone })
            report(
                "The left workspace's data store stays cached for its session cookies",
                leftStore != nil && autoreleasepool { registry.existingDataStore(for: store) } === leftStore)

            guard open("released-rest", into: rested) != nil, open("released-shown") != nil else {
                return report(restName, false)
            }
            var done = false
            autoreleasepool {
                Task {
                    await coordinator.relieve(.warning)
                    done = true
                }
            }
            report(restName, waitUntil { done } && waitUntil { rested.isGone })

            autoreleasepool { coordinator.switchTo(Workspace.anonymousID) }
            guard let anonymous = open("released-anonymous"),
                let ref = autoreleasepool(invoking: { coordinator.active.tabs[anonymous]?.store })
            else { return report(anonymousName, false) }
            autoreleasepool { anonymousStore.object = registry.existingDataStore(for: ref) }
            guard !anonymousStore.isGone else { return report(anonymousName, false) }
            autoreleasepool { coordinator.active.close(anonymous) }
            report(anonymousName, waitUntil { anonymousStore.isGone && registry.existingDataStore(for: ref) == nil })
            autoreleasepool { coordinator.switchTo(Workspace.defaultID) }
            settle()
        }

        /// Kept link icons (#30), in a temporary app directory, printing ok or FAILED for each: with icons already in
        /// Default's `Icons/` and no open tab, Default's pins and bookmarks and a custom workspace's shared pins draw
        /// them, and a file for no link is pruned; the session file holds no icon; a pin's own load keeps its icon, a
        /// later page in its tab does not change it; unpinning removes its file; Anonymous keeps none on disk. Pages
        /// are `data:` URLs and icons are handed to the model as its loader would, so no request goes out.
        private static func checkKeptIcons() {
            func report(_ name: String, _ passed: Bool) { print("Kept icons: \(name): \(passed ? "ok" : "FAILED")") }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !autoreleasepool(invoking: done), Date.now < deadline {
                    autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                }
                return autoreleasepool(invoking: done)
            }
            func icon(red: CGFloat) -> (image: NSImage, data: Data)? {
                guard
                    let context = CGContext(
                        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                context.setFillColor(red: red, green: 0.3, blue: 0.6, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                guard let made = context.makeImage() else { return nil }
                let image = NSImage(cgImage: made, size: .zero)
                guard let drawn = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                    let data = LinkIcon.png(from: drawn)
                else { return nil }
                return (image, data)
            }
            func page(_ name: String) -> URL? { URL(string: "data:text/html,<title>\(name)</title>") }

            let temporary = FileManager.default.temporaryDirectory.appending(
                path: "LodgeIcons-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let app = temporary.appending(path: "app", directoryHint: .isDirectory)
            let cache = LinkIconCache(directory: WorkspaceFiles.iconsDirectory(for: .default, in: app)!)
            let drawName = "Pins, bookmarks and shared pins draw their kept icons with no tab open"
            guard let pin = LinkLibrary.sample.links(on: .pins).first,
                let bookmark = LinkLibrary.sample.links(on: .bookmarks).first, let stored = icon(red: 0.9),
                let first = icon(red: 0.1), let later = icon(red: 0.5),
                (try? cache.write(stored.data, for: pin.id)) == true,
                (try? cache.write(stored.data, for: bookmark.id)) == true,
                (try? cache.write(stored.data, for: UUID())) == true
            else { return report(drawName, false) }

            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: app, downloads: nil, defaultLibrary: .sample,
                restDefaults: nil)
            coordinator.bringForwardHook = { _ in }
            coordinator.restAfter = .never
            let home = coordinator.active
            let homeDrawn =
                home.favicon(for: .link(pin, .pins, nil)) != nil
                && home.favicon(for: .link(bookmark, .bookmarks, nil)) != nil && home.tabs.tab(forLink: pin.id) == nil
            let pruned = waitUntil {
                let names = try? FileManager.default.contentsOfDirectory(
                    atPath: cache.directory.path(percentEncoded: false))
                return names?.count == 2
            }
            guard let work = try? coordinator.create(name: "Icons", symbol: "briefcase"),
                let workModel = coordinator.model(for: work.id)
            else { return report(drawName, false) }
            let sharedDrawn = workModel.favicon(for: .link(pin, .pins, nil)) != nil
            report(drawName, homeDrawn && sharedDrawn && pruned)
            let session = (try? coordinator.snapshot.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            report(
                "The session file holds no icon",
                !session.isEmpty && !session.contains("\"icon\"")
                    && !session.contains(stored.data.base64EncodedString()))

            // A pin opened on its own URL keeps the icon its page shows; a later page in its tab does not change it.
            coordinator.switchTo(Workspace.defaultID)
            let pane = firstPane(coordinator)
            let ownName = "A pin's own load keeps its icon"
            guard let own = page("own-icon"), let elsewhere = page("elsewhere-icon") else {
                return report(ownName, false)
            }
            let link = home.addPin(own, title: "Own")
            pane.openLink(link)
            guard let tab = home.tabs.tab(forLink: link.id),
                waitUntil({ home.tabs[tab.id]?.isLoading == false && home.tabs[tab.id]?.title == "own-icon" })
            else { return report(ownName, false) }
            home.setFavicon(first.image, for: tab.id)
            report(ownName, LinkIconCache(directory: cache.directory).icon(for: link.id) == first.data)
            _ = home.load(elsewhere, in: tab.id)
            let left = waitUntil {
                home.tabs[tab.id]?.isLoading == false && home.tabs[tab.id]?.title == "elsewhere-icon"
            }
            home.setFavicon(later.image, for: tab.id)
            report(
                "A later page in a pin's tab leaves its kept icon",
                left && home.tabs[tab.id]?.link == link.id
                    && LinkIconCache(directory: cache.directory).icon(for: link.id) == first.data)

            home.unpin(link.id)
            report(
                "Unpinning removes the pin's icon file",
                !FileManager.default.fileExists(atPath: cache.url(for: link.id).path(percentEncoded: false)))
            let anonymous = coordinator.model(for: Workspace.anonymousID)
            report("Anonymous keeps no icons on disk", anonymous != nil && anonymous?.icons == nil)
            autoreleasepool { home.close(tab.id) }
        }

        /// Places on disk (#26), in a temporary app directory: a tab that never sent a form rests with WebKit's state on
        /// disk, and a relaunched coordinator wakes it into a fresh view with its history and scroll; a tab that sent a
        /// form from its page, and one that sent it from an iframe, hold the posted body (a text and a password field)
        /// in WebKit's state in memory, yet write only their record, holding no part of the form, and wake to their
        /// address without history and without sending it again; closing a tab removes its place; a move carries the
        /// place, but not into Anonymous; Anonymous writes no file; deleting a workspace removes its places. Pages are
        /// `data:` URLs or served by `PlacesCheckScheme`, so no request goes out.
        private static func checkPlaces() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.3) {
                autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            }
            func waitUntil(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(5)
                while !autoreleasepool(invoking: done), Date.now < deadline { settle(0.05) }
                return autoreleasepool(invoking: done)
            }
            func pageValue(_ view: WKWebView, _ script: String) -> Any? {
                var answer: Any?
                var done = false
                view.evaluateJavaScript(script) { value, _ in
                    answer = value
                    done = true
                }
                _ = waitUntil { done }
                return answer
            }
            func page(_ name: String, _ body: String) -> URL? {
                let html = "<!doctype html><title>\(name)</title><body style='height:5000px'>\(body)</body>"
                return html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
                    .flatMap { URL(string: "data:text/html,\($0)") }
            }
            func files(in directory: URL) -> [URL] {
                let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: [.isRegularFileKey])
                return (enumerator?.allObjects as? [URL] ?? []).filter {
                    (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
            }
            /// Rests every unshown tab with a view of every built workspace.
            func rest(_ coordinator: WorkspaceCoordinator) {
                var done = false
                autoreleasepool {
                    Task {
                        await coordinator.relieve(.warning)
                        done = true
                    }
                }
                _ = waitUntil { done }
            }
            func makeCoordinator(_ app: URL, restoring snapshot: SessionSnapshot? = nil) -> WorkspaceCoordinator {
                autoreleasepool {
                    let coordinator = WorkspaceCoordinator(
                        restoring: snapshot, session: nil, appDirectory: app, downloads: nil, restDefaults: nil)
                    coordinator.bringForwardHook = { _ in }
                    coordinator.restAfter = .never
                    return coordinator
                }
            }
            let temporary = FileManager.default.temporaryDirectory.appending(
                path: "LodgePlaces-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let app = temporary.appending(path: "app", directoryHint: .isDirectory)
            let defaultPlaces = PlaceStore(directory: WorkspaceFiles.placesDirectory(for: .default, in: app)!)
            let cleanName = "A tab that never sent a form keeps WebKit's state on disk"
            let cleanWakeName = "After a relaunch it wakes from disk with its history and scroll"
            let formName = "A tab that sent a form writes only its record, without the form"
            // Served to every view made during this check, the relaunched coordinator's included.
            let scheme = PlacesCheckScheme()
            WebViewRegistry.selfCheckScheme = (PlacesCheckScheme.name, scheme)
            defer { WebViewRegistry.selfCheckScheme = nil }
            let markers = ["FIELDMARK7Q", "MARKERPW3X"]
            func checkURL(_ path: String) -> URL? { URL(string: "\(PlacesCheckScheme.name)://local/\(path)") }
            /// Every marker is in `data`.
            func holdsMarkers(_ data: Data?) -> Bool {
                guard let data else { return false }
                return (markers + ["pw="]).allSatisfy { data.range(of: Data($0.utf8)) != nil }
            }
            /// `data` is a file holding no part of the posted body.
            func holdsNoForm(_ data: Data) -> Bool {
                !data.isEmpty
                    && (markers + ["pw=", "field=", "FIELD", "MARK7Q", "MARKER", "PW3X"]).allSatisfy {
                        data.range(of: Data($0.utf8)) == nil
                    }
            }

            let first = makeCoordinator(app)
            let window = first.windows[0]
            var hostWindow: NSWindow? = autoreleasepool { host(root(first, window), size: NSSize(width: 900, height: 600)) }
            /// Opens a new tab of the shown workspace on `url`, waiting until it is titled `name`.
            func open(_ coordinator: WorkspaceCoordinator, _ name: String, _ url: URL?) -> TabID? {
                let window = coordinator.windows[0]
                let id: TabID? = autoreleasepool {
                    let pane = coordinator.pane(for: window)
                    window.locationPrompt = .newTab
                    pane.submitLocation("about:blank")
                    guard let id = pane.selectedID, let url, pane.model.load(url, in: id) else { return nil }
                    return id
                }
                guard let id,
                    waitUntil({
                        coordinator.registry.webView(for: id).map { $0.title == name && !$0.isLoading } == true
                    })
                else { return nil }
                settle()
                return id
            }
            /// Scrolls the tab's page to `y` and waits for the page to report it.
            func scroll(_ coordinator: WorkspaceCoordinator, _ id: TabID, to y: Double) -> Bool {
                guard let view = coordinator.registry.webView(for: id) else { return false }
                view.evaluateJavaScript("window.scrollTo(0, \(y))")
                return waitUntil { coordinator.active.reportedScroll(id).map { abs($0 - y) < 2 } == true }
            }

            // A clean tab: two pages, so it has a back entry, scrolled on the second.
            let model = first.active
            guard let clean = open(first, "place-1", page("place-1", "<p>one</p>")),
                let second = page("place-2", "<p>two</p>"), model.load(second, in: clean),
                waitUntil({ first.registry.webView(for: clean).map { $0.title == "place-2" && !$0.isLoading } == true }),
                scroll(first, clean, to: 1500)
            else { return report(cleanName, false) }

            // Two tabs fill a text field and a password field by script (so no address holds the markers) and send them
            // to the local scheme: one from its page, one from an iframe. WebKit's state of each holds the posted body,
            // which makes the check below meaningful.
            /// Opens `path`, titled `name`, and sends its form; the tab once the scheme has the post and loading ended.
            let fill = "f.value = ['FIELD', 'MARK7Q'].join(''); p.value = ['MARKER', 'PW3X'].join(''); form.requestSubmit()"
            func sendForm(_ coordinator: WorkspaceCoordinator, _ path: String, titled name: String) -> TabID? {
                guard let id = open(coordinator, name, checkURL(path)), let view = coordinator.registry.webView(for: id)
                else { return nil }
                let posted = scheme.postCount
                view.evaluateJavaScript(fill)
                guard waitUntil({
                    coordinator.active.hasSentForm(id) && scheme.postCount > posted && !view.isLoading
                })
                else { return nil }
                settle(0.5)
                return id
            }
            /// The tab's place in `store` is a record holding no part of the form.
            func writesOnlyRecord(_ store: PlaceStore, _ id: TabID) -> Bool {
                let bytes = (try? Data(contentsOf: store.url(for: id))) ?? Data()
                return store.read(id)?.isRecord == true && holdsNoForm(bytes)
            }
            guard let formPage = sendForm(first, "form-page", titled: "place-form-page"),
                waitUntil({ first.registry.webView(for: formPage)?.title == "place-sent-page" }),
                let formFrame = sendForm(first, "form-frame", titled: "place-form-frame"),
                scroll(first, formFrame, to: 900)
            else { return report(formName, false) }
            let sentPage = checkURL("sent-page")
            report(
                "The local scheme received both forms with their fields",
                scheme.postCount == 2 && scheme.posts.values.allSatisfy { body in markers.allSatisfy { body.contains($0) } })
            for (id, label) in [(formPage, "page"), (formFrame, "frame")] {
                report(
                    "A tab whose \(label) sent a form holds the posted body in WebKit's state in memory",
                    holdsMarkers(first.registry.webView(for: id)?.interactionState as? Data))
            }
            guard open(first, "place-shown", page("place-shown", "<p>shown</p>")) != nil else {
                return report(cleanName, false)
            }
            rest(first)
            let cleanRested = waitUntil { first.registry.webView(for: clean) == nil }
            let formsRested = waitUntil {
                first.registry.webView(for: formPage) == nil && first.registry.webView(for: formFrame) == nil
            }
            let cleanPlace = defaultPlaces.read(clean)
            report(cleanName, cleanRested && cleanPlace?.isRecord == false && cleanPlace?.url == second)
            for (id, label) in [(formPage, "page"), (formFrame, "frame")] {
                let bytes = (try? Data(contentsOf: defaultPlaces.url(for: id))) ?? Data()
                let place = defaultPlaces.read(id)
                let placed =
                    id == formPage
                    ? place?.url == sentPage : place.flatMap(\.scrollY).map { abs($0 - 900) < 2 } == true
                report(
                    "A tab whose \(label) sent a form writes only its record, holding no part of the form",
                    formsRested && place?.isRecord == true && holdsNoForm(bytes) && placed)
            }

            // A relaunch: a new coordinator from the session, its tabs with no state in memory.
            let snapshot = first.snapshot
            autoreleasepool {
                hostWindow?.close()
                hostWindow = nil
            }
            let relaunched = makeCoordinator(app, restoring: snapshot)
            let relaunchedWindow = relaunched.windows[0]
            let relaunchedHost = autoreleasepool {
                host(root(relaunched, relaunchedWindow), size: NSSize(width: 900, height: 600))
            }
            defer { relaunchedHost.close() }
            let pane = relaunched.pane(for: relaunchedWindow)
            func wake(_ id: TabID, titled name: String) -> WKWebView? {
                autoreleasepool { pane.select(id) }
                guard waitUntil({
                    relaunched.registry.webView(for: id).map { $0.title == name && !$0.isLoading } == true
                })
                else { return nil }
                settle(1)
                return relaunched.registry.webView(for: id)
            }
            if let view = wake(clean, titled: "place-2") {
                let y = pageValue(view, "window.scrollY") as? Double
                report(
                    cleanWakeName,
                    view.url == second && view.canGoBack && view.backForwardList.backItem?.title == "place-1"
                        && y.map { abs($0 - 1500) < 2 } == true)
            } else {
                report(cleanWakeName, false)
            }
            let pageWakeName = "After a relaunch the page's form tab wakes to its address without history, sending nothing"
            if let view = wake(formPage, titled: "place-sent-page") {
                report(
                    pageWakeName,
                    view.url == sentPage && !view.canGoBack && !relaunched.active.hasSentForm(formPage)
                        && scheme.postCount == 2 && scheme.gets["sent-page"] == 1)
            } else {
                report(pageWakeName, false)
            }
            let frameWakeName = "After a relaunch the frame's form tab wakes to its address and scroll without history"
            if let view = wake(formFrame, titled: "place-form-frame") {
                let y = pageValue(view, "window.scrollY") as? Double
                report(
                    frameWakeName,
                    !view.canGoBack && !relaunched.active.hasSentForm(formFrame) && scheme.postCount == 2
                        && y.map { abs($0 - 900) < 2 } == true)
            } else {
                report(frameWakeName, false)
            }
            autoreleasepool {
                relaunched.active.close(formPage)
                relaunched.active.close(formFrame)
            }
            report(
                "Closing a tab removes its place",
                defaultPlaces.read(formPage) == nil && defaultPlaces.read(formFrame) == nil)

            // A tab that sent a form, rested and woken from memory, still counts as having sent it: WebKit's state
            // came back with the body, so its next rest writes a record again.
            let rewokenName = "A tab that sent a form, woken from memory, stays marked and rests to a record again"
            if let again = sendForm(relaunched, "form-frame", titled: "place-form-frame"),
                open(relaunched, "place-again-shown", page("place-again-shown", "<p>shown</p>")) != nil
            {
                rest(relaunched)
                let firstRest = waitUntil { relaunched.registry.webView(for: again) == nil }
                    && writesOnlyRecord(defaultPlaces, again)
                defaultPlaces.remove(again)
                let woken = wake(again, titled: "place-form-frame")
                let stillMarked =
                    woken != nil && relaunched.active.hasSentForm(again)
                    && holdsMarkers(woken?.interactionState as? Data)
                _ = open(relaunched, "place-again-shown-2", page("place-again-shown-2", "<p>shown</p>"))
                rest(relaunched)
                let secondRest = waitUntil { relaunched.registry.webView(for: again) == nil }
                report(rewokenName, firstRest && stillMarked && secondRest && writesOnlyRecord(defaultPlaces, again))
                autoreleasepool { relaunched.active.close(again) }
            } else {
                report(rewokenName, false)
            }

            // A form sent into a new window: the popup it opens counts as having sent it.
            let popupName = "A popup opened by a sent form is marked and keeps only a record"
            let tabsBefore = Set(relaunched.active.tabs.tabs.map(\.id))
            if let opener = open(relaunched, "place-form-popup", checkURL("form-popup")) {
                relaunched.registry.webView(for: opener)?.evaluateJavaScript(fill)
                let popup: () -> TabID? = {
                    relaunched.active.tabs.tabs.first {
                        !tabsBefore.contains($0.id) && $0.id != opener
                            && relaunched.registry.webView(for: $0.id)?.title == "place-sent-popup"
                    }?.id
                }
                if waitUntil({ popup() != nil }), let popup = popup() {
                    settle(0.5)
                    let marked = relaunched.active.hasSentForm(popup) && !relaunched.active.hasSentForm(opener)
                    let inMemory = holdsMarkers(relaunched.registry.webView(for: popup)?.interactionState as? Data)
                    autoreleasepool { relaunched.keepLivePlaces() }
                    report(popupName, marked && inMemory && writesOnlyRecord(defaultPlaces, popup))
                } else {
                    report(popupName, false)
                }
                autoreleasepool { relaunched.active.close(opener) }
                settle()
            } else {
                report(popupName, false)
            }

            // Quitting with a tab still awake that sent a form: its place is a record too.
            let quitName = "Quitting with a live Default tab that sent a form writes only its record"
            if let live = sendForm(relaunched, "form-page", titled: "place-form-page") {
                autoreleasepool { relaunched.keepLivePlaces() }
                report(quitName, relaunched.registry.webView(for: live) != nil && writesOnlyRecord(defaultPlaces, live))
                autoreleasepool { relaunched.active.close(live) }
            } else {
                report(quitName, false)
            }

            // Moves: into a custom workspace the place goes along; into Anonymous it does not.
            let moveName = "A moved tab carries its place, and its old place goes"
            let made = autoreleasepool { try? relaunched.create(name: "Places", symbol: "briefcase") }
            guard let made, let customDirectory = WorkspaceFiles.placesDirectory(for: made, in: app) else {
                return report(moveName, false)
            }
            let customPlaces = PlaceStore(directory: customDirectory)
            let moved = autoreleasepool { relaunched.move(tab: clean, to: made.id) }
            let carried = relaunched.model(for: made.id)?.tabs.tabs.first { $0.url == second }
            report(
                moveName,
                moved && defaultPlaces.read(clean) == nil
                    && carried.flatMap { customPlaces.read($0.id) }.map { !$0.isRecord && $0.url == second } == true)
            if let carried {
                let movedAgain = autoreleasepool { relaunched.move(tab: carried.id, to: Workspace.anonymousID) }
                let arrived = relaunched.model(for: Workspace.anonymousID)?.tabs.tabs.first { $0.url == second }
                report(
                    "A tab moved into Anonymous drops its place",
                    movedAgain && customPlaces.read(carried.id) == nil && arrived != nil
                        && relaunched.model(for: Workspace.anonymousID)?.places == nil
                        && files(in: temporary).allSatisfy { !$0.lastPathComponent.contains(arrived!.id.uuidString) })
                if let arrived { autoreleasepool { relaunched.model(for: Workspace.anonymousID)?.close(arrived.id) } }
            }
            let movedFormName = "A moved tab that sent a form carries only its record"
            // Creating the workspace switched to it: the sender opens in Default.
            autoreleasepool { relaunched.switchTo(Workspace.defaultID) }
            if let sender = sendForm(relaunched, "form-page", titled: "place-form-page") {
                let tabsThere = Set(relaunched.model(for: made.id)?.tabs.tabs.map(\.id) ?? [])
                let movedForm = autoreleasepool { relaunched.move(tab: sender, to: made.id) }
                let arrived = relaunched.model(for: made.id)?.tabs.tabs.first { !tabsThere.contains($0.id) }
                report(
                    movedFormName,
                    movedForm && defaultPlaces.read(sender) == nil
                        && arrived.map { writesOnlyRecord(customPlaces, $0.id) } == true)
                if let arrived { autoreleasepool { relaunched.model(for: made.id)?.close(arrived.id) } }
            } else {
                report(movedFormName, false)
            }

            // Deleting the workspace removes its places.
            let deleteName = "Deleting a workspace removes its places"
            autoreleasepool { relaunched.switchTo(made.id) }
            let customQuitName = "Quitting with a live custom workspace tab that sent a form writes only its record"
            if let live = sendForm(relaunched, "form-page", titled: "place-form-page") {
                autoreleasepool { relaunched.keepLivePlaces() }
                report(
                    customQuitName,
                    relaunched.registry.webView(for: live) != nil && writesOnlyRecord(customPlaces, live))
            } else {
                report(customQuitName, false)
            }
            guard let kept = open(relaunched, "place-doomed", page("place-doomed", "<p>doomed</p>")),
                open(relaunched, "place-doomed-shown", page("place-doomed-shown", "<p>shown</p>")) != nil
            else { return report(deleteName, false) }
            rest(relaunched)
            guard waitUntil({ customPlaces.read(kept) != nil }) else { return report(deleteName, false) }
            autoreleasepool { relaunched.switchTo(Workspace.defaultID) }
            settle()
            var deleted: Bool?
            autoreleasepool { Task { deleted = await relaunched.delete(made.id) } }
            _ = waitUntil { deleted != nil }
            report(
                deleteName,
                deleted == true
                    && !FileManager.default.fileExists(
                        atPath: WorkspaceFiles.directory(for: made.id, in: app).path(percentEncoded: false)))

            // Anonymous, in an app directory of its own: resting and quitting write nothing at all.
            let anonymousApp = temporary.appending(path: "anonymous", directoryHint: .isDirectory)
            let anonymous = makeCoordinator(anonymousApp)
            let anonymousHost = autoreleasepool {
                host(root(anonymous, anonymous.windows[0]), size: NSSize(width: 900, height: 600))
            }
            defer { anonymousHost.close() }
            autoreleasepool { anonymous.switchTo(Workspace.anonymousID) }
            let anonymousName = "Anonymous writes no place, resting or quitting"
            guard let resting = open(anonymous, "place-anon", page("place-anon", "<p>anon</p>")),
                open(anonymous, "place-anon-shown", page("place-anon-shown", "<p>shown</p>")) != nil,
                scroll(anonymous, resting, to: 300)
            else { return report(anonymousName, false) }
            rest(anonymous)
            let anonymousRested = waitUntil { anonymous.registry.webView(for: resting) == nil }
            autoreleasepool { anonymous.keepLivePlaces() }
            report(anonymousName, anonymousRested && files(in: anonymousApp).isEmpty)
            for id in anonymous.active.tabs.tabs.map(\.id) { autoreleasepool { anonymous.active.close(id) } }
            autoreleasepool { anonymous.switchTo(Workspace.defaultID) }
            settle()
        }

        /// Workspace colours and Anonymous's look: an Anonymous window drawn in a light system appearance (it stays
        /// dark) and in a dark one (checked against a plain dark window's ground), a strip of Default's sidebar in each
        /// palette swatch in light and in dark, the Change Icon sheet with a colour chosen in both appearances, and the
        /// Anonymous address badge, compact in the sidebar and full in the rail mode's page header. The address is set
        /// but never loaded.
        private static func renderTheme(in directory: URL) {
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let size = NSSize(width: 1100, height: 700)

            let anonymous = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            anonymous.switchTo(Workspace.anonymousID)
            let pane = firstPane(anonymous)
            if let tab = pane.selected {
                pane.model.update(tab.id) { $0.url = URL(string: "https://www.example.com/private/page")! }
            }
            for mode in SidebarMode.allCases {
                defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
                snapshot(
                    root(anonymous).defaultAppStorage(defaults), size: size,
                    to: directory.appending(path: "layout-anonymous-badge-\(mode.rawValue).png"))
            }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            // The app's own appearance stands in for a light system, whatever this Mac is set to.
            do {
                let system = NSApp.appearance
                NSApp.appearance = NSAppearance(named: .aqua)
                defer { NSApp.appearance = system }
                snapshot(
                    root(anonymous).defaultAppStorage(defaults), size: size, appearance: NSAppearance(named: .aqua),
                    to: directory.appending(path: "layout-anonymous-light-system.png"))
            }
            // And a dark system, where Anonymous must still stand apart from a plain dark window.
            do {
                let system = NSApp.appearance
                NSApp.appearance = NSAppearance(named: .darkAqua)
                defer { NSApp.appearance = system }
                let dark = NSAppearance(named: .darkAqua)
                let shown = image(root(anonymous).defaultAppStorage(defaults), size: size, appearance: dark)
                try? shown?.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "layout-anonymous-dark-system.png"))
                let plain = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                let plainShown = image(root(plain).defaultAppStorage(defaults), size: size, appearance: dark)
                print(
                    "Anonymous ground stands apart from plain dark: "
                        + (groundsDiffer(shown, plainShown, size: size) ? "ok" : "FAILED"))
            }

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                let sidebarSize = NSSize(width: 900, height: 560)
                let sidebars: [CGImage] = WorkspaceColor.palette.compactMap { swatch in
                    let coordinator = WorkspaceCoordinator(
                        restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                    try? coordinator.setColor(Workspace.defaultID, swatch)
                    guard
                        let window = image(
                            root(coordinator).defaultAppStorage(defaults), size: sidebarSize,
                            appearance: NSAppearance(named: appearance))?.cgImage
                    else { return nil }
                    let scale = CGFloat(window.width) / sidebarSize.width
                    return window.cropping(
                        to: CGRect(x: 0, y: 0, width: SidebarMode.expanded.width * scale, height: CGFloat(window.height)))
                }
                let gap = 6
                guard sidebars.count == WorkspaceColor.palette.count, let first = sidebars.first,
                    let context = CGContext(
                        data: nil, width: (first.width + gap) * sidebars.count - gap, height: first.height,
                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                for (index, sidebar) in sidebars.enumerated() {
                    context.draw(
                        sidebar,
                        in: CGRect(x: index * (first.width + gap), y: 0, width: sidebar.width, height: sidebar.height))
                }
                if let strip = context.makeImage() {
                    try? NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:])?
                        .write(to: directory.appending(path: "layout-swatches-\(name).png"))
                }

                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                guard let work = try? coordinator.create(name: "Work", symbol: "briefcase", color: .purple)
                else { continue }
                coordinator.windows[0].workspaceEditor = .changeIcon(work.id)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults), size: size,
                    appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-sheet-color-\(name).png"))
                // Yellow, the palest swatch, for the selected icon's dark foreground.
                try? coordinator.setColor(work.id, .yellow)
                coordinator.windows[0].workspaceEditor = nil
                coordinator.windows[0].workspaceEditor = .changeIcon(work.id)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults), size: size,
                    appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-sheet-yellow-\(name).png"))
                guard appearance == .aqua else { continue }
                coordinator.switchTo(Workspace.anonymousID)
                coordinator.windows[0].workspaceEditor = .changeIcon(Workspace.anonymousID)
                snapshot(
                    root(coordinator).defaultAppStorage(defaults), size: size,
                    appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-sheet-anonymous.png"))
            }
        }

        /// Whether the window ground beside the page card (the strip right of it, and the one below) is clearly
        /// darker in `anonymous` than in `plain`.
        private static func groundsDiffer(_ anonymous: NSBitmapImageRep?, _ plain: NSBitmapImageRep?, size: NSSize)
            -> Bool
        {
            guard let anonymous, let plain else { return false }
            func brightness(_ rep: NSBitmapImageRep, at point: NSPoint) -> CGFloat? {
                let scale = CGFloat(rep.pixelsWide) / size.width
                guard let color = rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
                else { return nil }
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            let points = [NSPoint(x: size.width - 3, y: size.height / 2), NSPoint(x: size.width / 2, y: size.height - 3)]
            return points.allSatisfy { point in
                guard let dark = brightness(anonymous, at: point), let base = brightness(plain, at: point) else {
                    return false
                }
                return base - dark >= 0.05
            }
        }

        /// Anonymous's dark windows through the real path, printed ok or FAILED for each: the windows carry no
        /// appearance of the renderer's, so what they show is what WindowRegistrar and WindowAppearance set. The app's
        /// appearance is set light for the run, so the web view's system look differs from the dark window. Pages are
        /// `about:blank`, so no request goes out.
        private static func checkAppearance() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(until done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(3)
                while !done(), Date.now < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                return done()
            }
            func isDark(_ window: NSWindow) -> Bool { window.appearance?.name == .darkAqua }
            let system = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .aqua)
            defer { NSApp.appearance = system }
            let size = NSSize(width: 900, height: 600)

            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            let first = coordinator.windows[0]
            let second = coordinator.newWindow()
            second.locationPrompt = nil
            var hosts = [first, second].map { host(root(coordinator, $0), size: size) }
            defer { for window in hosts { window.close() } }
            let registered = settle { zip([first, second], hosts).allSatisfy { $0.nsWindow === $1 } }
            let lightOnDefault = hosts.allSatisfy { $0.appearance == nil }
            coordinator.switchTo(Workspace.anonymousID)
            report(
                "Anonymous browser windows are dark",
                registered && lightOnDefault && settle { hosts.allSatisfy(isDark) })

            let third = coordinator.newWindow()
            third.locationPrompt = nil
            let late = host(root(coordinator, third), size: size)
            hosts.append(late)
            report(
                "A window registered in Anonymous is dark",
                settle { third.nsWindow === late && isDark(late) })

            coordinator.switchTo(Workspace.defaultID)
            let leftAnonymous = settle { hosts.allSatisfy { $0.appearance == nil } }
            coordinator.switchTo(Workspace.anonymousID)
            let darkAgain = settle { hosts.allSatisfy(isDark) }
            report("Browser windows turn light leaving Anonymous and dark again", leftAnonymous && darkAgain)

            let model = coordinator.active
            let shown = coordinator.selections.shown(in: first.id)
            if let shown { model.update(shown) { $0.url = URL(string: "about:blank#anonymous")! } }
            let webView = { shown.flatMap { coordinator.registry.webView(for: $0) } }
            let inWindow = settle { webView()?.window === hosts[0] }
            report(
                "A web view in a dark window keeps the system look",
                inWindow && hosts[0].effectiveAppearance.name == .darkAqua
                    && webView()?.effectiveAppearance.name == NSApp.effectiveAppearance.name
                    && NSApp.effectiveAppearance.name == .aqua)

            coordinator.switchTo(Workspace.defaultID)
            report("Leaving Anonymous gives the windows back", settle { hosts.allSatisfy { $0.appearance == nil } })
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        /// Each workspace's own look through the real path, printed ok or FAILED for each: a page reports its
        /// workspace's `prefers-color-scheme` whatever the app's look, System follows the app live, a change reaches
        /// open pages with no reload, a switch gives the window its workspace's chrome, a page keeps its look in a
        /// window of another, Anonymous's chrome stays dark in any look, and a removed workspace's look is
        /// forgotten. Pages are `about:blank`, so no request goes out.
        private static func checkWorkspaceAppearance() {
            func report(_ name: String, _ passed: Bool) { print("Workspace look: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(until done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(3)
                while !done(), Date.now < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                return done()
            }
            func value(_ script: String, in view: WKWebView?) -> Any? {
                guard let view else { return nil }
                var answer: Any?
                var done = false
                view.evaluateJavaScript(script) { value, _ in
                    answer = value
                    done = true
                }
                _ = settle { done }
                return answer
            }
            func prefersDark(_ view: WKWebView?) -> Bool? {
                value("matchMedia('(prefers-color-scheme: dark)').matches", in: view) as? Bool
            }
            func becomes(_ view: WKWebView?, dark: Bool) -> Bool { settle { prefersDark(view) == dark } }
            let system = NSApp.appearance
            NSApp.appearance = NSAppearance(named: .aqua)
            defer { NSApp.appearance = system }

            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.bringForwardHook = { _ in }
            let window = coordinator.windows[0]
            window.locationPrompt = nil
            let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
            defer { hostWindow.close() }
            /// The page the window shows in the active workspace, on `about:blank`.
            func shownPage() -> WKWebView? {
                guard let shown = coordinator.selections.shown(in: window.id) else { return nil }
                let model = coordinator.active
                model.update(shown) { $0.url = URL(string: "about:blank")! }
                let view = model.view(for: shown)
                _ = settle { view?.isLoading == false }
                return view
            }
            guard let night = try? coordinator.create(name: "Night", symbol: "moon"),
                (try? coordinator.setAppearance(night.id, .dark)) != nil
            else { return report("a Dark workspace's page is dark in a light app", false) }
            let registered = settle { window.nsWindow === hostWindow }
            let nightPage = shownPage()
            report(
                "a Dark workspace's page is dark in a light app",
                registered && coordinator.activeWorkspaceID == night.id && becomes(nightPage, dark: true)
                    && nightPage?.appearance?.name == .darkAqua && hostWindow.appearance?.name == .darkAqua)

            _ = value("window.marker = 42", in: nightPage)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let stillDark = becomes(nightPage, dark: true)
            try? coordinator.setAppearance(night.id, .light)
            report(
                "a Light workspace's page is light in a dark app, changed with no reload",
                stillDark && becomes(nightPage, dark: false) && nightPage?.appearance?.name == .aqua
                    && hostWindow.appearance?.name == .aqua
                    && value("window.marker", in: nightPage) as? Int == 42)

            let stray = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled],
                backing: .buffered, defer: false)
            stray.isReleasedWhenClosed = false
            stray.appearance = NSAppearance(named: .darkAqua)
            let container = WebViewContainer()
            stray.contentView = container
            container.show(nightPage)
            report(
                "a page keeps its own workspace's look in a window of another",
                nightPage?.window === stray && nightPage?.effectiveAppearance.name == .aqua
                    && becomes(nightPage, dark: false))
            container.show(nil)
            stray.close()

            coordinator.switchTo(Workspace.defaultID)
            let defaultPage = shownPage()
            let followsDark = settle { hostWindow.appearance == nil } && becomes(defaultPage, dark: true)
            NSApp.appearance = NSAppearance(named: .aqua)
            report(
                "a switch gives the window its workspace's look, and System follows the app live",
                followsDark && becomes(defaultPage, dark: false))

            try? coordinator.setAppearance(Workspace.anonymousID, .light)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            coordinator.switchTo(Workspace.anonymousID)
            let anonymousPage = shownPage()
            report(
                "Anonymous's chrome stays dark while its page follows its own look",
                settle { hostWindow.appearance?.name == .darkAqua } && becomes(anonymousPage, dark: false))
            try? coordinator.setAppearance(Workspace.anonymousID, .system)
            coordinator.switchTo(Workspace.defaultID)
            let recorded = WindowAppearance.recorded(night.id) == .light
            coordinator.removeFromList(night.id)
            report(
                "a removed workspace's look is forgotten",
                recorded && WindowAppearance.recorded(night.id) == nil && coordinator.workspaces[night.id] == nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        /// Workspace colours, printed ok or FAILED for each: Default's and a custom workspace's colours survive the
        /// saved session; Anonymous keeps graphite and its sheet offers no colour row.
        private static func checkTheme() {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            guard let work = try? coordinator.create(name: "Work", symbol: "briefcase", color: .teal),
                (try? coordinator.setColor(Workspace.defaultID, .orange)) != nil
            else { return report("A workspace colour survives the saved session", false) }
            let saved = (try? coordinator.snapshot.encoded()).flatMap { try? SessionSnapshot.decode($0) }
            let restored = saved.map {
                WorkspaceCoordinator(restoring: $0, session: nil, appDirectory: nil, downloads: nil)
            }
            report(
                "A workspace colour survives the saved session",
                restored?.workspaces[work.id]?.color == .teal
                    && restored?.workspaces[Workspace.defaultID]?.color == .orange
                    && restored?.workspaces[Workspace.anonymousID]?.color == .graphite)

            // SwiftUI builds no accessibility tree off screen, so this asks the sheet's own predicate, against a
            // custom workspace's sheet that does offer the row; the list also refuses to colour Anonymous.
            var refused: WorkspaceList.EditError?
            do { try coordinator.setColor(Workspace.anonymousID, .red) } catch { refused = error }
            let anonymous = coordinator.workspaces[Workspace.anonymousID]
            report(
                "Anonymous's sheet has no colour row",
                !WorkspaceSheet.offersIconAndColor(.changeIcon(Workspace.anonymousID), target: anonymous)
                    && !WorkspaceSheet.offersIconAndColor(.create, target: anonymous)
                    && WorkspaceSheet.offersIconAndColor(.changeIcon(work.id), target: coordinator.workspaces[work.id])
                    && WorkspaceSheet.offersIconAndColor(.create, target: nil)
                    && refused == .anonymousIsFixed && anonymous?.color == .graphite)
        }

        /// The Settings tab in light, in dark and in Anonymous (in a light system), its download choices read from a
        /// defaults suite of its own, removed afterwards. Printed ok or FAILED: the page card follows the window's
        /// look, light in light and dark in dark and in Anonymous; ⌘, and the gear's `open(.settings)` select the
        /// one Settings tab, in place of the blank tab.
        private static func renderSettings(in directory: URL) {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            let settings = DownloadSettingsModel(defaults: defaults)
            let size = NSSize(width: 1100, height: 700)
            /// The page's ground in the middle of the card, below the form.
            let probe = NSPoint(x: (SidebarMode.expanded.width + size.width) / 2, y: size.height - 30)
            func brightness(_ rep: NSBitmapImageRep?) -> CGFloat? {
                guard let rep else { return nil }
                let scale = CGFloat(rep.pixelsWide) / size.width
                guard let color = rep.colorAt(x: Int(probe.x * scale), y: Int(probe.y * scale))?.usingColorSpace(.sRGB)
                else { return nil }
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }

            var grounds: [String: CGFloat] = [:]
            var opened = true
            for (name, anonymous, appearance) in [
                ("light", false, NSAppearance.Name.aqua), ("dark", false, .darkAqua), ("anonymous", true, .aqua),
            ] {
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                coordinator.bringForwardHook = { _ in }
                if anonymous { coordinator.switchTo(Workspace.anonymousID) }
                let window = coordinator.windows[0]
                window.locationPrompt = nil
                let pane = firstPane(coordinator)
                let blank = pane.selectedID
                coordinator.open(.settings)
                coordinator.open(.settings)
                let tab = pane.model.tab(showing: .settings)
                opened = opened && tab != nil && pane.selectedID == tab?.id && pane.model.tabs.tabs.count == 1
                    && blank != tab?.id
                // Anonymous's look comes from WindowRegistrar on a real window; this stands in for it.
                let look = NSAppearance(named: anonymous ? .darkAqua : appearance)
                let system = NSApp.appearance
                NSApp.appearance = NSAppearance(named: appearance)
                defer { NSApp.appearance = system }
                let shown = image(
                    root(coordinator).defaultAppStorage(defaults).environment(\.downloadSettings, settings), size: size,
                    appearance: look)
                try? shown?.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "layout-settings-\(name).png"))
                grounds[name] = brightness(shown)
            }
            report("⌘, and the gear open the one Settings tab in place of the blank tab", opened)
            report(
                "The Settings page follows the window's look, Anonymous included",
                (grounds["light"] ?? 0) > 0.8 && (grounds["dark"] ?? 1) < 0.3 && (grounds["anonymous"] ?? 1) < 0.3)
        }

        /// The fingerprint indicator in the address bar, on (the page read a fingerprint) and off (its site excepted),
        /// and the protection page opened from it with one more site turned off, each in light and dark; then the page
        /// in Anonymous, in its dark look. No page loads: the tab's view is built without loading and its reads are
        /// reported by hand.
        private static func renderProtection(in directory: URL) {
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            let size = NSSize(width: 1100, height: 700)
            let site = "example.com"
            /// A coordinator whose window shows a tab at `site` that read canvas and audio, in `workspace`.
            func scene(_ workspace: UUID = Workspace.defaultID) -> (WorkspaceCoordinator, BrowserPane, BrowserTab) {
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                coordinator.bringForwardHook = { _ in }
                if workspace != Workspace.defaultID { coordinator.switchTo(workspace) }
                coordinator.windows[0].locationPrompt = nil
                let pane = firstPane(coordinator)
                let model = pane.model
                let tab = BrowserTab(store: model.newTabStore(), url: URL(string: "https://www.\(site)/"), title: "Example")
                model.append(tab, load: false)
                coordinator.opened(tab.id, in: model, window: coordinator.windows[0])
                if let view = model.registry.webView(for: tab.id) {
                    model.didReadFingerprint(.canvas, from: view)
                    model.didReadFingerprint(.audio, from: view)
                }
                return (coordinator, pane, tab)
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                for isOff in [false, true] {
                    let (coordinator, _, _) = scene()
                    if isOff { coordinator.setFingerprint(off: true, site, for: Workspace.defaultID) }
                    snapshot(
                        root(coordinator).defaultAppStorage(defaults), size: size,
                        appearance: NSAppearance(named: appearance),
                        to: directory.appending(path: "layout-fingerprint-\(isOff ? "off" : "on")-\(name).png"))
                }
                let (coordinator, pane, _) = scene()
                coordinator.setFingerprint(off: true, "tracker.example", for: Workspace.defaultID)
                pane.openProtection()
                snapshot(
                    root(coordinator).defaultAppStorage(defaults), size: size, appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-protection-\(name).png"))
            }
            let (coordinator, pane, tab) = scene(Workspace.anonymousID)
            pane.model.setFingerprintProtection(false, for: "tracker.example", on: tab.store)
            pane.openProtection()
            snapshot(
                root(coordinator).defaultAppStorage(defaults), size: size, appearance: NSAppearance(named: .darkAqua),
                to: directory.appending(path: "layout-protection-anonymous.png"))
        }

        /// The sign-in sheet over the window of the tab that asked, in light and dark: a second try at a plain-http site
        /// with a realm and a name to prefill, so every line the sheet can show is there. No page loads; the sheet is
        /// laid out on its own and drawn where it would hang under the title bar.
        private static func renderAuth(in directory: URL) {
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            let size = NSSize(width: 1100, height: 700)
            let host = "wiki.team.example.com"
            let page = URL(string: "http://\(host):8080/wiki/")!
            let space = URLProtectionSpace(
                host: host, port: 8080, protocol: NSURLProtectionSpaceHTTP, realm: "Team wiki",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            guard
                let prompt = AuthPrompt(
                    space: space, previousFailureCount: 1, proposedUser: "alex", pageSite: nil,
                    navigation: Origin(url: page))
            else { return }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let name = appearance == .aqua ? "light" : "dark"
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                coordinator.bringForwardHook = { _ in }
                coordinator.windows[0].locationPrompt = nil
                let model = firstPane(coordinator).model
                let tab = BrowserTab(store: model.newTabStore(), url: page, title: "Team wiki")
                model.append(tab, load: false)
                coordinator.opened(tab.id, in: model, window: coordinator.windows[0])
                let look = NSAppearance(named: appearance)
                let (alert, _, _) = TabController.signInAlert(for: prompt)
                alert.window.appearance = look
                alert.layout()
                guard
                    let behind = image(root(coordinator).defaultAppStorage(defaults), size: size, appearance: look),
                    let panel = alert.window.contentView,
                    let sheet = panel.bitmapImageRepForCachingDisplay(in: panel.bounds),
                    let picture = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: behind.pixelsWide, pixelsHigh: behind.pixelsHigh,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { continue }
                panel.cacheDisplay(in: panel.bounds, to: sheet)
                picture.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
                behind.draw(in: NSRect(origin: .zero, size: size))
                let frame = NSRect(
                    x: (size.width - panel.bounds.width) / 2, y: size.height - 28 - panel.bounds.height,
                    width: panel.bounds.width, height: panel.bounds.height)
                var ground = NSColor.windowBackgroundColor.cgColor
                var edge = NSColor.separatorColor.cgColor
                alert.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    ground = NSColor.windowBackgroundColor.cgColor
                    edge = NSColor.separatorColor.cgColor
                }
                let outline = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
                NSColor(cgColor: ground)?.setFill()
                outline.fill()
                NSColor(cgColor: edge)?.setStroke()
                outline.stroke()
                sheet.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
                try? picture.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "layout-auth-\(name).png"))
            }
        }

        /// The plain-http warning (D8) in place of a tab's page, in light and dark, and in Anonymous's dark look with its
        /// own wording. No page loads: the warning is put up by hand on a tab whose view never loaded. Printed ok or
        /// FAILED: the page under it is the window's ground, not the web view's, in each look.
        private static func renderPlainHTTP(in directory: URL) {
            func report(_ name: String, _ passed: Bool) { print("Plain http: \(name): \(passed ? "ok" : "FAILED")") }
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            let size = NSSize(width: 1100, height: 700)
            let page = URL(string: "http://wiki.team.example.com:8080/wiki/")!
            /// The page's ground near the card's bottom, below the warning.
            let probe = NSPoint(x: (SidebarMode.expanded.width + size.width) / 2, y: 30)
            var grounds: [String: CGFloat] = [:]
            for (name, anonymous, appearance) in [
                ("light", false, NSAppearance.Name.aqua), ("dark", false, .darkAqua), ("anonymous", true, .darkAqua),
            ] {
                let coordinator = WorkspaceCoordinator(
                    restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
                coordinator.bringForwardHook = { _ in }
                if anonymous { coordinator.switchTo(Workspace.anonymousID) }
                coordinator.windows[0].locationPrompt = nil
                let model = firstPane(coordinator).model
                let tab = BrowserTab(store: model.newTabStore(), url: nil)
                model.append(tab, load: false)
                coordinator.opened(tab.id, in: model, window: coordinator.windows[0])
                model.showPlainHTTPWarning(page, for: tab.id)
                let look = NSAppearance(named: appearance)
                let system = NSApp.appearance
                NSApp.appearance = look
                defer { NSApp.appearance = system }
                let shown = image(root(coordinator).defaultAppStorage(defaults), size: size, appearance: look)
                try? shown?.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "layout-insecure-\(name).png"))
                if let shown {
                    let scale = CGFloat(shown.pixelsWide) / size.width
                    let color = shown.colorAt(x: Int(probe.x * scale), y: shown.pixelsHigh - Int(probe.y * scale))?
                        .usingColorSpace(.sRGB)
                    grounds[name] = color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }
                }
            }
            report(
                "the warning page follows the window's look, Anonymous included",
                (grounds["light"] ?? 0) > 0.8 && (grounds["dark"] ?? 1) < 0.3 && (grounds["anonymous"] ?? 1) < 0.3)
        }

        /// The Safari-family User-Agent (D1), printed ok or FAILED for each: a Default tab's page, an Anonymous tab's
        /// and a popup the page opens all report a `navigator.userAgent` ending in `Version/<n> Safari/605.1.15`. Where
        /// `<n>` came from is printed; falling back while `/Applications/Safari.app` exists fails. Pages are inline HTML
        /// and `about:blank`, so no request goes out.
        private static func checkUserAgent() {
            func report(_ name: String, _ passed: Bool) { print("User-Agent: \(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
            let expected = WebViewRegistry.userAgentApplicationName
            let installed = WebViewRegistry.installedSafariVersion
            let fromSafari = installed.map { expected == "Version/\($0) Safari/605.1.15" } ?? false
            let source =
                fromSafari ? "from Safari's bundle, \(installed ?? "")" : "fallback, \(SafariUserAgent.fallbackVersion)"
            print("User-Agent: version \(source)")
            report(
                "the version is the installed Safari's when Safari is there",
                fromSafari || !FileManager.default.fileExists(atPath: "/Applications/Safari.app"))
            func userAgent(of view: WKWebView) -> String? {
                var answer: String?
                var done = false
                view.evaluateJavaScript("navigator.userAgent") { value, _ in
                    answer = value as? String
                    done = true
                }
                let deadline = Date.now.addingTimeInterval(5)
                while !done, Date.now < deadline { settle() }
                return answer
            }
            func endsRight(_ agent: String?) -> Bool {
                agent?.wholeMatch(of: /Mozilla\/5\.0 .* Version\/[0-9]+(\.[0-9]+)* Safari\/605\.1\.15/) != nil
                    && agent?.hasSuffix(expected) == true
            }
            for anonymous in [false, true] {
                let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
                coordinator.bringForwardHook = { _ in }
                if anonymous { coordinator.switchTo(Workspace.anonymousID) }
                let window = coordinator.windows[0]
                window.locationPrompt = nil
                let hostWindow = host(root(coordinator, window), size: NSSize(width: 900, height: 600))
                defer { hostWindow.close() }
                let pane = coordinator.pane(for: window)
                let model = pane.model
                let name = anonymous ? "an Anonymous tab" : "a Default tab"
                let tab = BrowserTab(store: model.newTabStore(), url: nil)
                model.append(tab, load: false)
                guard let view = model.view(for: tab.id, load: false) else { return report("\(name)'s page", false) }
                view.loadHTMLString("<!doctype html><title>agent</title><body>x</body>", baseURL: nil)
                let deadline = Date.now.addingTimeInterval(5)
                while view.title != "agent" || view.isLoading, Date.now < deadline { settle() }
                report("\(name)'s page", endsRight(userAgent(of: view)))
                let before = Set(model.tabs.tabs.map(\.id))
                view.evaluateJavaScript("window.open('about:blank')")
                let opened = Date.now.addingTimeInterval(5)
                var popup: WKWebView?
                while popup == nil, Date.now < opened {
                    settle()
                    popup = model.tabs.tabs.map(\.id).first { !before.contains($0) }.flatMap(model.registry.webView(for:))
                }
                report("a popup from \(name)", popup.map { endsRight(userAgent(of: $0)) } ?? false)
                for id in model.tabs.tabs.map(\.id) { model.registry.detach(tab: id) }
            }
        }

        /// An off-screen window hosting `view`, never shown; it is not freed on closing, so closing it is safe.
        private static func host(_ view: some View, size: NSSize) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: false)
            return window
        }

        /// The first window's view of the active workspace.
        private static func firstPane(_ coordinator: WorkspaceCoordinator) -> BrowserPane {
            coordinator.pane(for: coordinator.windows[0])
        }

        private static func root(_ coordinator: WorkspaceCoordinator, _ window: WindowState? = nil) -> BrowserRoot {
            BrowserRoot(coordinator: coordinator, window: window ?? coordinator.windows[0])
        }

        /// The tab a window remembers in the model's workspace: what it shows there on switching to it.
        private static func remembered(_ coordinator: WorkspaceCoordinator, _ model: BrowserModel) -> BrowserTab? {
            coordinator.selections.remembered(in: model.workspaceID).flatMap { model.tabs[$0] }
        }

        /// Which location prompt a render opens: ⌘T's empty one or ⌘L's on the selected page.
        enum PromptRender { case newTab, current }

        /// The History tab over sample visits from today back three days, in a store that lives only in memory: in
        /// light, in dark, searching, and Anonymous's not-kept page. Printed ok or FAILED: Show All History's
        /// `open(.history)` gives each workspace one History tab; the search filters the list; Anonymous's tab says
        /// history is not kept; the page follows the window's look; and the model knows whether a History page shows
        /// whatever order pages appear and disappear in, a switch between workspaces that each show one included.
        private static func renderHistory(in directory: URL) {
            func report(_ name: String, _ passed: Bool) { print("\(name): \(passed ? "ok" : "FAILED")") }
            func settle(_ done: () -> Bool) -> Bool {
                let deadline = Date.now.addingTimeInterval(3)
                while !done(), Date.now < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
                return done()
            }
            guard let store = try? HistoryStore.inMemory() else { return report("History opens in memory", false) }
            let sites = [
                ("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer Documentation"),
                ("https://www.swift.org/blog/", "Blog | Swift.org"),
                ("https://github.com/groue/GRDB.swift", "GitHub - groue/GRDB.swift: A toolkit for SQLite databases"),
                ("https://news.ycombinator.com/", "Hacker News"),
                ("https://zh.wikipedia.org/wiki/臺北市", "臺北市 - 維基百科，自由的百科全書"),
                ("https://example.com/untitled", ""),
            ]
            // Oldest first, as a clock would record them; the store coalesces a revisit only against the newest.
            Task {
                for index in (0..<24).reversed() {
                    let (address, title) = sites[index % sites.count]
                    let date = Date.now.addingTimeInterval(-Double(index) * 4 * 3600)
                    _ = try? await store.record(URL(string: address)!, title: title, at: date)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            func visits(_ model: HistoryModel) -> [HistoryVisit] { model.days.flatMap(\.visits) }

            // The model alone, its pages coming and going in every order a window or a switch can produce.
            let model = HistoryModel { _ in }
            model.show(store, state: .ready)
            let (a, b, c, d) = (UUID(), UUID(), UUID(), UUID())
            model.pageAppeared(a)
            model.pageAppeared(b)
            model.pageAppeared(b)
            model.pageDisappeared(a)
            var counted = model.isVisible
            model.pageDisappeared(a)
            counted = counted && model.isVisible
            model.pageDisappeared(b)
            counted = counted && !model.isVisible
            model.pageDisappeared(c)
            counted = counted && !model.isVisible
            model.pageAppeared(c)
            counted = counted && model.isVisible && settle { !visits(model).isEmpty }
            // A switch: the new workspace's page appears before the old one's goes, then the other way round.
            model.pageAppeared(d)
            model.pageDisappeared(c)
            counted = counted && model.isVisible && !visits(model).isEmpty
            model.pageDisappeared(d)
            counted = counted && !model.isVisible && model.days.isEmpty
            model.pageAppeared(a)
            counted = counted && model.isVisible && settle { !visits(model).isEmpty }
            model.pageDisappeared(a)
            report("History knows a page shows whatever order pages appear and disappear in", counted)

            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
            let size = NSSize(width: 1100, height: 700)
            let coordinator = WorkspaceCoordinator(
                restoring: nil, session: nil, appDirectory: nil, downloads: nil, defaultLibrary: .sample)
            coordinator.bringForwardHook = { _ in }
            let history = coordinator.history
            let window = coordinator.windows[0]
            window.locationPrompt = nil
            let pane = firstPane(coordinator)
            func historyTabs(_ model: BrowserModel) -> Int { model.tabs.tabs.filter { $0.lodgePage == .history }.count }
            /// Default's history is the sample store; the other workspaces have none in a renderer with no folder.
            func enter(_ id: UUID) {
                coordinator.switchTo(id)
                if id == Workspace.defaultID { history.show(store, state: .ready) }
            }

            let blank = pane.selectedID
            coordinator.open(.history)
            coordinator.open(.history)
            let defaultTab = pane.model.tab(showing: .history)
            var single = defaultTab != nil && pane.selectedID == defaultTab?.id && historyTabs(pane.model) == 1
                && pane.model.tabs.tabs.count == 1 && blank != defaultTab?.id
            guard let work = try? coordinator.create(name: "Work", symbol: "briefcase"),
                let personal = try? coordinator.create(name: "Personal", symbol: "house")
            else { return report("Workspaces for History", false) }
            enter(work.id)
            coordinator.open(.history)
            coordinator.open(.history)
            let workModel = firstPane(coordinator).model
            single = single && historyTabs(workModel) == 1 && firstPane(coordinator).selected?.lodgePage == .history
            enter(Workspace.defaultID)
            single = single && historyTabs(pane.model) == 1 && historyTabs(workModel) == 1
                && pane.selected?.lodgePage == .history
            report("Show All History opens one History tab per workspace", single)

            // A real window: its History page counts while shown, across switches that rebuild the window's content.
            let hosted = host(root(coordinator).defaultAppStorage(defaults), size: size)
            defer { hosted.close() }
            var visible = settle { history.isVisible }
            enter(work.id)
            visible = visible && settle { history.isVisible }
            enter(personal.id)
            visible = visible && settle { !history.isVisible }
            enter(Workspace.defaultID)
            visible = visible && settle { history.isVisible && !visits(history).isEmpty }

            history.query = "swift"
            let all = 24
            let searched = settle { !history.isSearchPending && !visits(history).isEmpty }
            let found = visits(history)
            report(
                "Searching History shows only the matching visits",
                searched && found.count < all
                    && found.allSatisfy {
                        $0.title.localizedCaseInsensitiveContains("swift")
                            || $0.url.absoluteString.localizedCaseInsensitiveContains("swift")
                    })
            // Emptied, not closed: closing would close the coordinator's window too.
            hosted.contentView = nil
            visible = visible && settle { !history.isVisible }
            report("A History tab counts as shown exactly while a window shows it, across workspace switches", visible)

            /// The page's ground: the median over a grid on the card, where text is the minority.
            func ground(_ rep: NSBitmapImageRep?) -> CGFloat? {
                guard let rep else { return nil }
                let scale = CGFloat(rep.pixelsWide) / size.width
                var values: [CGFloat] = []
                for x in stride(from: SidebarMode.expanded.width + 40, to: size.width - 40, by: 23) {
                    for y in stride(from: 80, to: size.height - 40, by: 17) {
                        guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
                        else { continue }
                        values.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                    }
                }
                return values.isEmpty ? nil : values.sorted()[values.count / 2]
            }
            func render(_ name: String, look: NSAppearance.Name) -> CGFloat? {
                let shown = image(root(coordinator).defaultAppStorage(defaults), size: size, appearance: NSAppearance(named: look))
                try? shown?.representation(using: .png, properties: [:])?
                    .write(to: directory.appending(path: "layout-history-\(name).png"))
                return ground(shown)
            }
            let system = NSApp.appearance
            defer { NSApp.appearance = system }
            NSApp.appearance = NSAppearance(named: .aqua)
            let search = render("search", look: .aqua)
            history.query = ""
            let light = render("light", look: .aqua)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let dark = render("dark", look: .darkAqua)
            NSApp.appearance = NSAppearance(named: .aqua)

            enter(Workspace.anonymousID)
            coordinator.open(.history)
            let anonymousTab = firstPane(coordinator).selected?.lodgePage == .history
            let notKept = history.state == .notKept
            // Anonymous's look comes from WindowRegistrar on a real window; this stands in for it.
            let anonymous = render("not-kept", look: .darkAqua)
            enter(Workspace.defaultID)
            report(
                "Anonymous's History tab says history is not kept",
                anonymousTab && notKept && history.state == .ready)
            report(
                "The History page follows the window's look, Anonymous included",
                (light ?? 0) > 0.8 && (search ?? 0) > 0.8 && (dark ?? 1) < 0.3 && (anonymous ?? 1) < 0.3)
        }

        /// One sample item per D5 state, newest first; the second finished one stands for a moved file.
        private static let sampleDownloads: [DownloadItem] = {
            let now = Date.now
            func item(
                _ name: String, _ state: DownloadItem.State, received: Int64 = 0, total: Int64? = nil,
                method: String = "GET", minutesAgo: Double
            ) -> DownloadItem {
                DownloadItem(
                    sourceURL: URL(string: "https://downloads.example/\(name)"), method: method, fileName: name,
                    state: state, receivedBytes: received, totalBytes: total,
                    startedAt: now.addingTimeInterval(-minutesAgo * 60))
            }
            return [
                item("Lodge-Notes.pdf", .waitingForLocation, minutesAgo: 0),
                item("Xcode_26.xip", .running, received: 12_300_000, total: 40_000_000, minutesAgo: 1),
                item("stream-capture.mov", .running, received: 12_300_000, minutesAgo: 2),
                item("swift-6.2-RELEASE.pkg", .finished, received: 40_000_000, total: 40_000_000, minutesAgo: 5),
                item("Old Invoice.pdf", .finished, received: 182_000, total: 182_000, minutesAgo: 30),
                item("dataset.zip", .failed(reason: "The network connection was lost."), minutesAgo: 60),
                item("form-export.csv", .failed(reason: "The form could not be sent."), method: "POST", minutesAgo: 70),
                item("photos.zip", .cancelled, minutesAgo: 90),
                item("archive.tar.gz", .interrupted, received: 5_000_000, total: 90_000_000, minutesAgo: 120),
            ]
        }()

        /// The popover with every D5 state, the empty popover, and the button's four looks.
        private static func renderDownloads(in directory: URL) {
            let list = DownloadList(items: sampleDownloads)
            let missing: Set<UUID> = [list.items[4].id]
            // Every row at once, no scrolling.
            let all = DownloadsList(
                list: list, missing: missing, onAction: { _, _ in }, clear: {}, visibleRows: list.items.count)
            snapshot(
                all.frame(maxHeight: .infinity, alignment: .top), size: NSSize(width: DownloadsList.width, height: 580),
                title: "Downloads", to: directory.appending(path: "layout-downloads.png"))
            let empty = DownloadsList(list: DownloadList(), missing: [], onAction: { _, _ in }, clear: {})
            snapshot(
                empty.frame(maxHeight: .infinity, alignment: .top), size: NSSize(width: DownloadsList.width, height: 130),
                title: "Downloads", to: directory.appending(path: "layout-downloads-empty.png"))
            let looks: [(DownloadOverallProgress, Bool)] = [
                (.none, false), (.determinate(0.3), false), (.indeterminate, false), (.none, true),
            ]
            let strip = VStack(spacing: 16) {
                ForEach([DownloadsButtonLabel.barSymbolSize, SidebarMode.railSymbolSize], id: \.self) { size in
                    HStack(spacing: 20) {
                        ForEach(looks.indices, id: \.self) {
                            DownloadsButtonLabel(progress: looks[$0].0, hasUnseen: looks[$0].1, size: size)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            snapshot(
                strip, size: NSSize(width: 240, height: 120),
                to: directory.appending(path: "layout-downloads-button.png"))
        }

        /// Draws `view` in an off-screen window to a PNG file; with no `title`, the title bar is hidden as the
        /// browser's is.
        private static func snapshot(
            _ view: some View, size: NSSize, title: String? = nil, appearance: NSAppearance? = nil, to url: URL
        ) {
            let rep = image(view, size: size, title: title, appearance: appearance)
            try? rep?.representation(using: .png, properties: [:])?.write(to: url)
        }

        /// Draws `view` in an off-screen window, as `snapshot` does, and returns the picture.
        private static func image(
            _ view: some View, size: NSSize, title: String? = nil, appearance: NSAppearance? = nil
        ) -> NSBitmapImageRep? {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.appearance = appearance
            if let title {
                window.title = title
            } else {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
            }
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: false)
            // Let SwiftUI settle its first layout passes.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.layoutIfNeeded()

            guard let content = window.contentView?.superview ?? window.contentView,
                let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { return nil }
            content.cacheDisplay(in: content.bounds, to: rep)
            return rep
        }
    }
    /// Layout self-checks only: a local `lodge-check:` scheme serving the form pages of `checkPlaces` and recording what
    /// is posted to it, so a form is sent with no network.
    @MainActor
    final class PlacesCheckScheme: NSObject, WKURLSchemeHandler {
        static let name = "lodge-check"
        /// Each POST's urlencoded body, by the path it was last sent to.
        private(set) var posts: [String: String] = [:]
        /// How many POSTs arrived in all.
        private(set) var postCount = 0
        /// How many GETs each path had.
        private(set) var gets: [String: Int] = [:]

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let path = url.lastPathComponent
            if task.request.httpMethod == "POST" {
                posts[path] = String(decoding: Self.body(of: task.request), as: UTF8.self)
                postCount += 1
            } else {
                gets[path, default: 0] += 1
            }
            let fields = "<input id=f name=field><input id=p type=password name=pw>"
            let body: String =
                switch path {
                case "form-page":
                    "<form id=form method=post action='sent-page'>\(fields)</form>"
                case "form-popup":
                    "<form id=form method=post target=_blank action='sent-popup'>\(fields)</form>"
                case "form-frame":
                    "<iframe name=sink src='blank'></iframe>"
                        + "<form id=form method=post target=sink action='sent-frame'>\(fields)</form>"
                default: ""
                }
            let html = "<!doctype html><title>place-\(path)</title><body style='height:5000px'>\(body)</body>"
            let data = Data(html.utf8)
            task.didReceive(
                URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        private static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }
#endif
