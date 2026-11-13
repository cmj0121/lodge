import Foundation
import Synchronization
import os

/// The writes the recorder makes, so tests can stand in a store that fails.
protocol HistoryWriting: Sendable {
    func record(_ url: URL, title: String, at date: Date) async throws -> Int64
    func refresh(_ url: URL, title: String, at date: Date) async throws -> Int64?
    func updateTitle(of id: Int64, to title: String) async throws
}

extension HistoryStore: HistoryWriting {}

/// Turns tab navigation events into history visits. Events are applied one at a time, in the order sent, on a
/// single task. A `.title` carries the URL it is the title of, so it lands only on that page's visit, even when
/// the `.committed` before it was dropped. At most `queueLimit` events wait to be applied; under a flood the
/// oldest are dropped, which only loses history.
public final class HistoryRecorder: Sendable {
    public enum Event: Equatable, Sendable {
        case committed(tab: UUID, url: URL, title: String), urlChanged(tab: UUID, url: URL, title: String)
        case seen(tab: UUID, url: URL), title(tab: UUID, url: URL, title: String), closed(tab: UUID)
    }

    /// What the recorder remembers about one tab: the URL it shows, the visit its titles belong to, and the
    /// rows it added lately with the newest of them, which outlive a navigation for `rateWindow`.
    private struct TabState {
        var lastURL: URL?
        var visit: (id: Int64, url: URL)?
        var inserts: [Date] = []
        var latest: Int64?

        /// A state for a newly shown `url` that keeps the tab's insert history.
        func showing(_ url: URL) -> TabState {
            TabState(lastURL: url, inserts: inserts, latest: latest)
        }
    }

    /// Numbers the events as they are sent and tracks how far the consumer got, so `drain` waits outside the
    /// event queue and a full queue can never drop it.
    private final class Progress: Sendable {
        struct State {
            var sent = 0
            var done = 0
            var waiting: [(upTo: Int, continuation: CheckedContinuation<Void, Never>)] = []
        }

        let state = Mutex(State())

        /// Marks every event up to number `done` applied or dropped and resumes the drains that waited on them.
        func finished(upTo done: Int) {
            let ready = state.withLock { state in
                state.done = done
                let ready = state.waiting.filter { $0.upTo <= done }
                state.waiting.removeAll { $0.upTo <= done }
                return ready
            }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    /// Events waiting beyond this many drop the oldest.
    static let queueLimit = 1000

    /// A tab adds at most this many rows per `rateWindow`; past that its visits that would add a row are dropped,
    /// while those that refresh the newest row still apply.
    static let rateLimit = 30
    static let rateWindow: TimeInterval = 60

    /// Longer URLs are not recorded at all: a cut URL would open a different page.
    static let urlLimit = 4096

    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    private let clock: @Sendable () -> Date
    private let items: AsyncStream<(event: Event, date: Date, number: Int)>.Continuation
    private let progress = Progress()

    public convenience init(store: HistoryStore, clock: @escaping @Sendable () -> Date = Date.init) {
        self.init(writing: store, clock: clock)
    }

    init(writing store: any HistoryWriting, clock: @escaping @Sendable () -> Date) {
        self.clock = clock
        let (stream, items) = AsyncStream<(event: Event, date: Date, number: Int)>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.queueLimit))
        self.items = items
        Task { [progress] in
            var tabs: [UUID: TabState] = [:]
            // Dropped events are the oldest, so reaching number n means every event up to n is applied or dropped.
            for await item in stream {
                await Self.apply(item.event, at: item.date, to: &tabs, store: store)
                progress.finished(upTo: item.number)
            }
        }
    }

    deinit {
        items.finish()
    }

    public func send(_ event: Event) {
        let date = clock()
        // Numbered and queued under one lock, so the queue holds the events in number order.
        progress.state.withLock { state in
            state.sent += 1
            items.yield((event, date, state.sent))
        }
    }

    /// Waits until every event sent before this call has been applied or dropped.
    public func drain() async {
        await withCheckedContinuation { continuation in
            let waits = progress.state.withLock { state in
                guard state.done < state.sent else { return false }
                state.waiting.append((state.sent, continuation))
                return true
            }
            if !waits { continuation.resume() }
        }
    }

    private static func apply(_ event: Event, at date: Date, to tabs: inout [UUID: TabState], store: any HistoryWriting)
        async
    {
        do {
            switch event {
            // The new page replaces the tab's state before the write, so a failed write leaves no visit for a
            // later title to land on.
            case .committed(let tab, let url, let title):
                try await show(url, title: title, at: date, in: tab, of: &tabs, store: store)
            case .urlChanged(let tab, let url, let title):
                guard tabs[tab]?.lastURL != url else { return }
                try await show(url, title: title, at: date, in: tab, of: &tabs, store: store)
            case .seen(let tab, let url):
                tabs[tab, default: TabState()].lastURL = url
            // A second guard behind `HistoryEventFilter.titleChanged`, for any other sender.
            case .title(let tab, let url, let title):
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let state = tabs[tab],
                    state.lastURL == url, let visit = state.visit, visit.url == url
                else { return }
                try await store.updateTitle(of: visit.id, to: title)
            case .closed(let tab):
                tabs[tab] = nil
            }
        } catch {
            logger.error("Could not record history: \(error, privacy: .public)")
        }
    }

    /// Makes `url` the tab's page and records it when it is a web page of at most `urlLimit` bytes; anything
    /// else leaves no visit for later titles to land on. Past the tab's `rateLimit` it only refreshes the newest
    /// row, and a visit that would add one is dropped.
    private static func show(
        _ url: URL, title: String, at date: Date, in tab: UUID, of tabs: inout [UUID: TabState],
        store: any HistoryWriting
    ) async throws {
        var state = tabs[tab]?.showing(url) ?? TabState(lastURL: url)
        state.inserts.removeAll { date.timeIntervalSince($0) >= rateWindow }
        tabs[tab] = state
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.absoluteString.utf8.count <= urlLimit
        else { return }
        let stored = withoutCredentials(url)
        guard state.inserts.count < rateLimit else {
            tabs[tab]?.visit = try await store.refresh(stored, title: title, at: date).map { ($0, url) }
            return
        }
        let id = try await store.record(stored, title: title, at: date)
        // The store hands back an existing row when it coalesces a revisit; only a new row counts.
        if id != state.latest {
            tabs[tab]?.inserts.append(date)
            tabs[tab]?.latest = id
        }
        tabs[tab]?.visit = (id, url)
    }

    /// `url` without its user and password, which history must not keep.
    private static func withoutCredentials(_ url: URL) -> URL {
        guard url.user != nil || url.password != nil,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }
}
