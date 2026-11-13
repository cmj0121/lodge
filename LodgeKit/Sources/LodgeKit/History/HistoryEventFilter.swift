import Foundation

/// Picks the history event one tab's web view callback sends: a tab that still exists, on any store, is recorded
/// (whether its workspace keeps history is up to its model's recorder), a restore load's commit is only seen, and the
/// url observation's initial value and its changes while loading (commits, which `committed` covers) send nothing;
/// neither does a blank title, which WebKit sets at every main-frame commit before `didCommit`. A nil `store` means
/// the tab is gone; an anonymous tab has its own `.ephemeral` store, and keeps no history because its model has no
/// recorder.
public struct HistoryEventFilter: Sendable {
    private let tab: TabID
    private var sawInitialURL = false

    public init(tab: TabID) {
        self.tab = tab
    }

    /// A main-frame commit; `isRestore` when it is the commit of the load that restored the tab.
    public func committed(_ url: URL, title: String, store: StoreRef?, isRestore: Bool) -> HistoryRecorder.Event? {
        guard store != nil else { return nil }
        return isRestore ? .seen(tab: tab, url: url) : .committed(tab: tab, url: url, title: title)
    }

    /// A url observation callback; the first one is the observation's initial value.
    public mutating func urlChanged(_ url: URL?, title: String, store: StoreRef?, isLoading: Bool)
        -> HistoryRecorder.Event?
    {
        guard sawInitialURL else {
            sawInitialURL = true
            return nil
        }
        guard store != nil, !isLoading, let url else { return nil }
        return .urlChanged(tab: tab, url: url, title: title)
    }

    /// The primary blank-title guard: WebKit blanks the title at a commit, before the new page's visit exists.
    /// `url` is the page the title belongs to, the web view's URL when the title changed.
    public func titleChanged(_ title: String, url: URL?, store: StoreRef?) -> HistoryRecorder.Event? {
        guard store != nil, let url, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return .title(tab: tab, url: url, title: title)
    }

    /// A load ended: its final URL, so a pushState or replaceState made while loading is recorded too (the
    /// recorder drops it when it is the URL the commit already recorded, and records web pages only).
    public func loadFinished(_ url: URL?, title: String, store: StoreRef?) -> HistoryRecorder.Event? {
        guard store != nil, let url else { return nil }
        return .urlChanged(tab: tab, url: url, title: title)
    }
}
