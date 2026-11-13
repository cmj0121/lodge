#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI
    import WebKit

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, find
    /// open, and the shortcut overlay and the location prompt in light and dark), the History window from an in-memory history, and the Downloads popover and button
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
            checkDeletion(to: directory.appending(path: "layout-delete.png"))
            checkAnonymous()
            checkPrivateDownloadRow()
            checkSharedPins(to: directory.appending(path: "layout-shared-pins.png"))
            checkMoveTabs()
            checkTwoWindows()
            checkShownElsewhere(in: directory)
            checkStepSkipsShownElsewhere()
            checkExternalLinks()
            renderSettings(to: directory.appending(path: "layout-settings.png"))
            renderHistory(to: directory.appending(path: "layout-history.png"))
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
        /// both appearances, a Rename sheet opened for it anyway, and the History window while it is shown. Prints
        /// ok or FAILED for: History says Not Kept on Anonymous and leaves that state on Default.
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
                let notKept = coordinator.history.state == .notKept
                snapshot(
                    HistoryView(model: coordinator.history), size: NSSize(width: 640, height: 600), title: "History",
                    to: directory.appending(path: "layout-history-not-kept.png"))
                coordinator.switchTo(Workspace.defaultID)
                let left = coordinator.history.state != .notKept
                print("History is Not Kept on Anonymous: \(notKept && left ? "ok" : "FAILED")")
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

        /// The Settings window, its download choices read from a defaults suite of its own, removed afterwards.
        private static func renderSettings(to url: URL) {
            let suiteName = "dev.lodge.selfcheck.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else { return }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            snapshot(
                SettingsView(model: DownloadSettingsModel(defaults: defaults)).frame(height: 300),
                size: NSSize(width: 480, height: 300),
                title: "Settings", to: url)
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

        /// The History window over sample visits from today back three days, in a store that lives only in memory.
        private static func renderHistory(to url: URL) {
            guard let store = try? HistoryStore.inMemory() else { return }
            let sites = [
                ("https://developer.apple.com/documentation/swiftui", "SwiftUI | Apple Developer Documentation"),
                ("https://www.swift.org/blog/", "Blog | Swift.org"),
                ("https://github.com/groue/GRDB.swift", "GitHub - groue/GRDB.swift: A toolkit for SQLite databases"),
                ("https://news.ycombinator.com/", "Hacker News"),
                ("https://zh.wikipedia.org/wiki/臺北市", "臺北市 - 維基百科，自由的百科全書"),
                ("https://example.com/untitled", ""),
            ]
            // Oldest first, as a clock would record them; the store coalesces a revisit only against the newest.
            let done = Task {
                for index in (0..<24).reversed() {
                    let (address, title) = sites[index % sites.count]
                    let date = Date.now.addingTimeInterval(-Double(index) * 4 * 3600)
                    _ = try? await store.record(URL(string: address)!, title: title, at: date)
                }
            }
            let model = HistoryModel { _ in }
            Task {
                await done.value
                model.show(store, state: .ready)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            snapshot(HistoryView(model: model), size: NSSize(width: 640, height: 600), title: "History", to: url)
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

        /// Draws `view` in an off-screen window; with no `title`, the title bar is hidden as the browser's is.
        private static func snapshot(
            _ view: some View, size: NSSize, title: String? = nil, appearance: NSAppearance? = nil, to url: URL
        ) {
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
            else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
