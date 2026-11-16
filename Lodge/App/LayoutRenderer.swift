#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI
    import WebKit

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, find
    /// open, and the shortcut overlay and the location prompt in light and dark), workspace colours and
    /// Anonymous's dark window, the Settings tab, the History tab from an in-memory history, and the Downloads popover and button
    /// from sample items, to PNG files off screen, then exits. It never shows a window or takes focus,
    /// so it can run while someone uses the machine. The only download is a `data:` URL saved to a temporary folder.
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
            renderSettings(in: directory)
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
#endif
