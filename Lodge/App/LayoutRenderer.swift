#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, and
    /// find open) and the History window, from an in-memory history, to PNG files off screen, then
    /// exits. It never shows a window or takes focus, so it can run while someone uses the machine.
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
            renderHistory(to: directory.appending(path: "layout-history.png"))
            print(directory.path(percentEncoded: false))
            exit(0)
        }

        private static func render(_ mode: SidebarMode, find: Bool, to url: URL) {
            // A throwaway defaults suite, so rendering never changes the user's saved sidebar mode.
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = BrowserModel(defaultLibrary: .sample)
            // Opens the sample's folder, so the render shows a nested bookmark.
            for case .folder(let folder) in model.library.bookmarks.children { model.setFolderExpanded(folder.id, true) }
            if let bookmark = model.library.links(on: .bookmarks).first { model.openLink(bookmark, load: false) }
            if find {
                model.showFind()
                model.findText = "lodge"
            }
            snapshot(BrowserView(model: model).defaultAppStorage(defaults), size: NSSize(width: 1100, height: 700), to: url)
        }

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
            let model = HistoryModel(browser: BrowserModel(defaultLibrary: .sample))
            Task {
                await done.value
                model.attach(store)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            snapshot(HistoryView(model: model), size: NSSize(width: 640, height: 600), title: "History", to: url)
        }

        /// Draws `view` in an off-screen window; with no `title`, the title bar is hidden as the browser's is.
        private static func snapshot(_ view: some View, size: NSSize, title: String? = nil, to url: URL) {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
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
