#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI

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
