import AppKit
import LodgeKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        openHistory()
        restoreDownloads()
    }

    func applicationWillTerminate(_ notification: Notification) {
        downloads.cancelAllForQuit()
        store.schedule(browser.snapshot)
        store.flush()
        do {
            try historyStore?.close()
        } catch {
            Self.logger.error("Could not close history: \(error.localizedDescription, privacy: .public)")
        }
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
