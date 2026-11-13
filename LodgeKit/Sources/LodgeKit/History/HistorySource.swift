import Foundation

/// What the History window reads and clears; `HistoryStore` is the real one, and a stand-in can fail on purpose.
public protocol HistorySource: Sendable {
    func page(after cursor: HistoryVisit?, limit: Int) async throws -> [HistoryVisit]
    func search(_ query: String, limit: Int) async throws -> [HistoryVisit]
    func clearAll() async throws
    func changes() -> AsyncStream<Void>
}

extension HistoryStore: HistorySource {}
