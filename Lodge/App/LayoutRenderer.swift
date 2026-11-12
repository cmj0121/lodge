#if DEBUG
    import AppKit
    import LodgeKit
    import SwiftUI

    /// Debug aid: `Lodge -renderLayout YES` draws the window's layout (both sidebar modes, and
    /// find open) to PNG files off screen, then
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
            print(directory.path(percentEncoded: false))
            exit(0)
        }

        private static func render(_ mode: SidebarMode, find: Bool, to url: URL) {
            // A throwaway defaults suite, so rendering never changes the user's saved sidebar mode.
            let suite = "dev.lodge.render-layout"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(mode.rawValue, forKey: SidebarMode.defaultsKey)
            defer { defaults.removePersistentDomain(forName: suite) }

            let model = BrowserModel()
            if let bookmark = model.library.links(on: .bookmarks).first { model.openLink(bookmark, load: false) }
            if find {
                model.showFind()
                model.findText = "lodge"
            }
            let view = BrowserView(model: model).defaultAppStorage(defaults)
            let size = NSSize(width: 1100, height: 700)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
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
