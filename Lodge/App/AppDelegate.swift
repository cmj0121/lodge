import AppKit
import LodgeKit
import WebKit
import os

/// Owns the browser, the session it is saved to, the history it records, the History window's model and the
/// downloads. All are built on first use, after `LodgeApp.init`, so a layout render (which exits there) never reads
/// or writes the session, history or downloads files.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    private lazy var store = SessionStore()
    /// The history file, nil until it has opened off the main actor, and for the run when it cannot open.
    private(set) var historyStore: HistoryStore?

    /// The History window's model; it gets the store when the file has opened.
    private(set) lazy var history = HistoryModel(browser: browser)

    /// The downloads, kept in memory only when Application Support cannot be found.
    private(set) lazy var downloads: DownloadManager = {
        do {
            return DownloadManager(directory: try SessionStore.appDirectory())
        } catch {
            DownloadManager.logger.error("Downloads are not saved: \(error.localizedDescription, privacy: .public)")
            return DownloadManager(directory: nil)
        }
    }()

    private(set) lazy var browser: BrowserModel = {
        let browser = BrowserModel(restoring: store.load())
        browser.onSnapshotChange = { [store] in store.schedule($0) }
        browser.downloads = downloads
        return browser
    }()

    /// The ⌘+ alias of Zoom In (D9), which a menu item cannot carry beside its ⌘= key, and ⌘/ outside the page (D10).
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        openHistory()
        restoreDownloads()
        installKeyMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        downloads.cancelAllForQuit()
        store.schedule(browser.snapshot)
        store.flush()
        do {
            try historyStore?.close()
        } catch {
            Self.logger.error("Could not close history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// In the browser window, runs Zoom In for ⌘+ when it can zoom in, and toggles the shortcut help for ⌘/ when
    /// focus is not in a web view, swallowing the key; any other key, and ⌘/ inside the page, passes on.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isZoomInAlias = event.characters == "+" && flags.subtracting(.shift) == [.command]
            let isShortcutHelp = event.characters == "/" && flags == [.command]
            guard isZoomInAlias || isShortcutHelp else { return event }
            let handled = MainActor.assumeIsolated {
                guard let self, self.isBrowserWindowKey else { return false }
                if isZoomInAlias {
                    guard self.browser.canZoomIn else { return false }
                    self.browser.zoomIn()
                } else {
                    guard !Self.isInWebView(NSApp.keyWindow?.firstResponder) else { return false }
                    self.browser.toggleShortcutHelp()
                }
                return true
            }
            return handled ? nil : event
        }
    }

    /// The responder is a web view or a view inside one, so the page owns its keys.
    private static func isInWebView(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// The key window shows the selected tab's web view, so it is the browser window.
    private var isBrowserWindowKey: Bool {
        guard let key = NSApp.keyWindow, let id = browser.tabs.selectedID else { return false }
        return browser.registry.webView(for: id)?.window === key
    }

    /// Loads downloads.json off the main actor, interrupting what was running at the last quit and deleting the
    /// partials an earlier run left, then hands the list to the manager.
    private func restoreDownloads() {
        let cutoff = downloads.createdAt
        let folderBookmark = UserDefaults.standard.data(forKey: DownloadSettings.folderKey)
        Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    DownloadManager.load(
                        from: try SessionStore.appDirectory(), createdBefore: cutoff, folderBookmark: folderBookmark)
                }.value
                downloads.restore(saved)
            } catch {
                DownloadManager.logger.error("Cannot find downloads: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Opens the history file off the main actor (opening checks the whole file), then starts recording visits and
    /// hands it to the History window.
    private func openHistory() {
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try HistoryStore.open(directory: SessionStore.appDirectory())
                }.value
                historyStore = opened
                browser.historyRecorder = HistoryRecorder(store: opened)
                history.attach(opened)
            } catch {
                Self.logger.error("History is unavailable: \(error.localizedDescription, privacy: .public)")
                history.storeFailed()
            }
        }
    }
}
