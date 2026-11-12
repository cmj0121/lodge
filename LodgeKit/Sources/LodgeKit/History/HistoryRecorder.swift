import Foundation
import os

/// The writes the recorder makes, so tests can stand in a store that fails.
protocol HistoryWriting: Sendable {
    func record(_ url: URL, title: String, at date: Date) async throws -> Int64
    func updateTitle(of id: Int64, to title: String) async throws
}

extension HistoryStore: HistoryWriting {}

/// Turns tab navigation events into history visits. Events are applied one at a time, in the order sent, on a
/// single task, so a `.title` after a `.committed` always finds the visit it belongs to.
public final class HistoryRecorder: Sendable {
    public enum Event: Sendable {
        case committed(tab: UUID, url: URL, title: String), urlChanged(tab: UUID, url: URL, title: String)
        case seen(tab: UUID, url: URL), title(tab: UUID, title: String), closed(tab: UUID)
    }

    private enum Item: Sendable {
        case event(Event, at: Date)
        case drained(CheckedContinuation<Void, Never>)
    }

    /// What the recorder remembers about one tab: the URL it shows and the visit its titles belong to.
    private struct TabState {
        var lastURL: URL?
        var visit: (id: Int64, url: URL)?
    }

    private static let logger = Logger(subsystem: "dev.lodge", category: "history")

    private let clock: @Sendable () -> Date
    private let items: AsyncStream<Item>.Continuation

    public convenience init(store: HistoryStore, clock: @escaping @Sendable () -> Date = Date.init) {
        self.init(writing: store, clock: clock)
    }

    init(writing store: any HistoryWriting, clock: @escaping @Sendable () -> Date) {
        self.clock = clock
        let (stream, items) = AsyncStream<Item>.makeStream()
        self.items = items
        Task {
            var tabs: [UUID: TabState] = [:]
            for await item in stream {
                switch item {
                case .event(let event, let date):
                    await Self.apply(event, at: date, to: &tabs, store: store)
                case .drained(let continuation):
                    continuation.resume()
                }
            }
        }
    }

    deinit {
        items.finish()
    }

    public func send(_ event: Event) {
        items.yield(.event(event, at: clock()))
    }

    /// Waits until every event sent before this call has been applied.
    public func drain() async {
        await withCheckedContinuation { items.yield(.drained($0)) }
    }

    private static func apply(_ event: Event, at date: Date, to tabs: inout [UUID: TabState], store: any HistoryWriting)
        async
    {
        do {
            switch event {
            // The new page replaces the tab's state before the write, so a failed write leaves no visit for a
            // later title to land on.
            case .committed(let tab, let url, let title):
                tabs[tab] = TabState(lastURL: url)
                tabs[tab]?.visit = try await visit(url, title: title, at: date, store: store)
            case .urlChanged(let tab, let url, let title):
                guard tabs[tab]?.lastURL != url else { return }
                tabs[tab] = TabState(lastURL: url)
                tabs[tab]?.visit = try await visit(url, title: title, at: date, store: store)
            case .seen(let tab, let url):
                tabs[tab, default: TabState()].lastURL = url
            case .title(let tab, let title):
                guard let state = tabs[tab], let visit = state.visit, visit.url == state.lastURL else { return }
                try await store.updateTitle(of: visit.id, to: title)
            case .closed(let tab):
                tabs[tab] = nil
            }
        } catch {
            logger.error("Could not record history: \(error, privacy: .public)")
        }
    }

    /// Records `url` when it is a web page; other schemes leave no visit for later titles to land on.
    private static func visit(_ url: URL, title: String, at date: Date, store: any HistoryWriting) async throws
        -> (id: Int64, url: URL)?
    {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return (try await store.record(url, title: title, at: date), url)
    }
}
