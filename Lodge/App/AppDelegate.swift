import AppKit
import LodgeKit

/// Owns the browser and the session it is saved to. Both are built on first use, after
/// `LodgeApp.init`, so a layout render (which exits there) never reads or writes the session file.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var store = SessionStore()

    private(set) lazy var browser: BrowserModel = {
        let browser = BrowserModel(restoring: store.load())
        browser.onSnapshotChange = { [store] in store.schedule($0) }
        return browser
    }()

    func applicationWillTerminate(_ notification: Notification) {
        store.schedule(browser.snapshot)
        store.flush()
    }
}
