#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI
    import WebKit

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, find
    /// open, and the shortcut overlay and the location prompt in light and dark), the History window from an in-memory history, and the Downloads popover and button
    /// from sample items, to PNG files off screen, then exits. It never shows a window or takes focus,
    /// so it can run while someone uses the machine. No download runs.
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
            checkDeletion(to: directory.appending(path: "layout-delete.png"))
            checkAnonymous()
            checkSharedPins(to: directory.appending(path: "layout-shared-pins.png"))
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
            let model = coordinator.active
            // Opens the sample's folder, so the render shows a nested bookmark.
            for case .folder(let folder) in model.library.bookmarks.children { model.setFolderExpanded(folder.id, true) }
            if let bookmark = model.library.links(on: .bookmarks).first { model.openLink(bookmark, load: false) }
            // An in-memory manager over one running sample, so the sidebar shows the Downloads ring.
            let downloads = DownloadManager(directory: nil, defaults: defaults)
            let running = sampleDownloads.filter { $0.state == .running && $0.totalBytes != nil }
            downloads.restore(DownloadList(items: running))
            model.downloads = downloads
            if find {
                model.showFind()
                model.findText = "lodge"
            }
            model.isShortcutHelpVisible = shortcutHelp
            switch prompt {
            case .newTab: model.newTab()
            case .current: model.focusAddressBar()
            case nil: break
            }
            snapshot(
                BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
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
                        BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults),
                        size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                        to: directory.appending(path: "layout-workspaces-\(mode.rawValue)-\(name).png"))
                }
                defaults.set(SidebarMode.expanded.rawValue, forKey: SidebarMode.defaultsKey)
                coordinator.window.workspaceEditor = .create
                snapshot(
                    BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-sheet-\(name).png"))
                coordinator.window.workspaceEditor = .changeIcon(work.id)
                snapshot(
                    BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-icon-\(name).png"))
                coordinator.window.workspaceEditor = .rename(work.id)
                snapshot(
                    BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults),
                    size: NSSize(width: 1100, height: 700), appearance: NSAppearance(named: appearance),
                    to: directory.appending(path: "layout-workspace-rename-\(name).png"))
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
                BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
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
                snapshot(BrowserRoot(coordinator: coordinator), size: NSSize(width: 800, height: 500), to: url)
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

            let coordinator = WorkspaceCoordinator(restoring: nil, session: nil, appDirectory: nil, downloads: nil)
            coordinator.switchTo(Workspace.anonymousID)
            let model = coordinator.active
            guard let tab = model.selected, case .ephemeral = tab.store,
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
            guard let blank = model.selected else { return report("Anonymous session leaves no URLs", false) }
            model.update(blank.id) { $0.url = bookmark }
            model.addLink(.bookmarks, from: blank.id)
            model.openLink(SavedLink(url: URL(string: "https://\(secret)/page")!, title: "Secret"), load: false)
            let downloads = DownloadList(items: [
                DownloadItem(
                    sourceURL: URL(string: "https://\(secret)/file.zip"), fileName: "file.zip", state: .finished,
                    startedAt: .now, store: model.selected?.store),
            ])
            let session = (try? coordinator.snapshot.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let saved = (try? JSONEncoder().encode(downloads.persistable())).map { String(decoding: $0, as: UTF8.self) }
            report(
                "Anonymous session leaves no URLs",
                !session.isEmpty && !session.contains(secret) && session.contains("kept-bookmark.example")
                    && saved.map { !$0.contains(secret) } == true && model.tabs.tabs.contains { $0.url?.host() == secret })
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
            let model = coordinator.active
            snapshot(
                BrowserRoot(coordinator: coordinator).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700),
                to: url)
            report(
                "Custom workspace shows Default's pins",
                model.sidebar.pins.map(\.title) == LinkLibrary.sample.links(on: .pins).map(\.title)
                    && model.sidebar.pins.allSatisfy { $0.tab == nil } && model.library.links(on: .pins).isEmpty)

            let page = URL(string: "about:blank#pinned")!
            guard let tab = model.selected else { return report("Pinning in a custom workspace adds to Default", false) }
            model.update(tab.id) { $0.url = page }
            model.togglePinSelectedTab()
            let defaultPins = coordinator.pins
            report(
                "Pinning in a custom workspace adds to Default",
                defaultPins.count == LinkLibrary.sample.links(on: .pins).count + 1 && defaultPins.last?.url == page
                    && model.selected?.link == nil && model.library.links(on: .pins).isEmpty
                    && coordinator.activeWorkspace.id == work.id && model.isSelectedTabPinned
                    && model.sidebar.pins.count == defaultPins.count)

            guard let pin = defaultPins.last else { return report("Opening a pin switches to Default", false) }
            model.activate(.link(pin))
            let home = coordinator.active
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
