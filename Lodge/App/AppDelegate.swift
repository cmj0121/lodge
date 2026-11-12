import AppKit
import LodgeKit
import os

/// Owns the browser, the session it is saved to and the history it records. All are built on first use, after
/// `LodgeApp.init`, so a layout render (which exits there) never reads or writes the session or history files.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    private lazy var store = SessionStore()
    /// The history file, nil until it has opened off the main actor, and for the run when it cannot open.
    private(set) var historyStore: HistoryStore?

    private(set) lazy var browser: BrowserModel = {
        let browser = BrowserModel(restoring: store.load())
        browser.onSnapshotChange = { [store] in store.schedule($0) }
        return browser
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        openHistory()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.schedule(browser.snapshot)
        store.flush()
    }

    /// Opens the history file off the main actor (opening checks the whole file), then starts recording visits.
    private func openHistory() {
        Task {
            do {
                let history = try await Task.detached(priority: .userInitiated) {
                    try HistoryStore.open(directory: SessionStore.appDirectory())
                }.value
                historyStore = history
                browser.historyRecorder = HistoryRecorder(store: history)
            } catch {
                Self.logger.error("History is unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
