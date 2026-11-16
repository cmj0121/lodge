import Foundation
import Observation

/// A page the suggestion list can offer: an open tab, a pin or bookmark, or a page from history.
public struct SuggestionCandidate: Hashable, Sendable {
    public let url: URL
    public let title: String
    public let lastUsed: Date?
    public let useCount: Int
    /// Set for an open tab.
    public let tab: TabID?

    public init(url: URL, title: String, lastUsed: Date? = nil, useCount: Int = 0, tab: TabID? = nil) {
        self.url = url
        self.title = title
        self.lastUsed = lastUsed
        self.useCount = useCount
        self.tab = tab
    }

    /// The tabs that show or keep an address, in their order, except `shown` (the tab the field is the address of).
    public static func openTabs(_ tabs: [BrowserTab], except shown: TabID?) -> [SuggestionCandidate] {
        tabs.compactMap { tab in
            guard tab.id != shown, let url = tab.url else { return nil }
            return SuggestionCandidate(url: url, title: tab.displayTitle, tab: tab.id)
        }
    }

    /// The links in their order.
    public static func links(_ links: [SavedLink]) -> [SuggestionCandidate] {
        links.map { SuggestionCandidate(url: $0.url, title: $0.title) }
    }
}

/// One row of the suggestion list.
public struct Suggestion: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case search, openTab(TabID), bookmark, history }
    public let kind: Kind
    public let title: String
    /// nil for `.search`, which runs the words with the engine on Return.
    public let url: URL?
}

/// Orders what the suggestion list shows for the words typed; reads nothing, so it never touches the network.
public enum SuggestionRanker {
    public static let limit = 8

    /// How closely a candidate matches the words; a lower one is closer.
    enum Match: Int, Comparable {
        case hostPrefix, titleWordPrefix, substring

        static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Row 1 always `.search` ("Search <words> with <engine>"); then open tabs, bookmarks (Default's pins count
    /// here), history; at most `limit` rows; a URL shows once (earliest group wins). In a group: match quality
    /// (host prefix without `www.` > title word prefix > substring of URL or title, case/diacritic-insensitive),
    /// then `lastUsed` desc, then `useCount` desc. Blank words give [].
    public static func rank(
        words: String, engine: SearchEngine, openTabs: [SuggestionCandidate], bookmarks: [SuggestionCandidate],
        history: [SuggestionCandidate]
    ) -> [Suggestion] {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        let folded = fold(words)
        var rows = [
            Suggestion(
                kind: .search, title: String(localized: "Search \(words) with \(engine.name)", bundle: .module),
                url: nil)
        ]
        var seen = Set<URL>()
        let groups: [([SuggestionCandidate], (SuggestionCandidate) -> Suggestion.Kind?)] = [
            (openTabs, { $0.tab.map(Suggestion.Kind.openTab) }),
            (bookmarks, { _ in .bookmark }),
            (history, { _ in .history }),
        ]
        for (candidates, kind) in groups {
            for candidate in ordered(candidates, matching: folded) {
                guard let kind = kind(candidate), seen.insert(candidate.url).inserted else { continue }
                guard rows.count < limit else { return rows }
                let title = candidate.title.isEmpty ? candidate.url.absoluteString : candidate.title
                rows.append(Suggestion(kind: kind, title: title, url: candidate.url))
            }
        }
        return rows
    }

    /// Visits folded per URL: latest `visitedAt` as `lastUsed`, count as `useCount`; the latest visit's title, else
    /// the latest non-empty one. Most recent first.
    public static func candidates(from visits: [HistoryVisit]) -> [SuggestionCandidate] {
        var byURL: [URL: (latest: HistoryVisit, title: String, count: Int)] = [:]
        for visit in visits {
            guard let folded = byURL[visit.url] else {
                byURL[visit.url] = (visit, visit.title, 1)
                continue
            }
            let isLater = visit.visitedAt > folded.latest.visitedAt
            let latest = isLater ? visit : folded.latest
            let title = (isLater && !visit.title.isEmpty) || folded.title.isEmpty ? visit.title : folded.title
            byURL[visit.url] = (latest, title, folded.count + 1)
        }
        return byURL.values
            .sorted { ($0.latest.visitedAt, $0.latest.id) > ($1.latest.visitedAt, $1.latest.id) }
            .map { latest, title, count in
                SuggestionCandidate(url: latest.url, title: title, lastUsed: latest.visitedAt, useCount: count)
            }
    }

    /// The text to complete to when `typed` (no spaces) is a prefix of a candidate's host without `www.` (the host
    /// itself when `typed` starts with `www.`), or, once `typed` reaches past the host, of host+path: the
    /// best-ranked candidate's such text, nil otherwise. Only `http`/`https` pages complete. Case-insensitive; the
    /// result keeps `typed` as typed and adds the rest, so it is always longer than `typed`. Best-ranked: a host
    /// before a host+path, then `lastUsed` desc, then `useCount` desc, then the order given.
    public static func completion(for typed: String, among candidates: [SuggestionCandidate]) -> String? {
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let keepsWWW = typed.range(of: "www.", options: [.caseInsensitive, .anchored]) != nil
        var best: (rest: String, isHost: Bool, candidate: SuggestionCandidate)?
        for candidate in candidates {
            guard let scheme = candidate.url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                var host = candidate.url.host()?.lowercased(), !host.isEmpty
            else { continue }
            if !keepsWWW, host.hasPrefix("www.") { host.removeFirst(4) }
            let found: (String, Bool)
            if let rest = rest(of: host, after: typed) {
                found = (rest, true)
            } else if typed.count > host.count, let rest = rest(of: host + candidate.url.path(), after: typed) {
                found = (rest, false)
            } else {
                continue
            }
            guard let current = best else {
                best = (found.0, found.1, candidate)
                continue
            }
            let isBetter =
                found.1 != current.isHost ? found.1 : comesFirst(candidate, current.candidate, otherwise: false)
            if isBetter { best = (found.0, found.1, candidate) }
        }
        return best.map { typed + $0.rest }
    }

    /// What `text` has after `typed` when `typed` is a strict prefix of it, ignoring case; nil otherwise.
    private static func rest(of text: String, after typed: String) -> String? {
        guard let found = text.range(of: typed, options: [.caseInsensitive, .anchored]),
            found.upperBound < text.endIndex
        else { return nil }
        return String(text[found.upperBound...])
    }

    /// `lhs` before `rhs` by `lastUsed` desc (none last), then `useCount` desc; `otherwise` when they tie.
    private static func comesFirst(_ lhs: SuggestionCandidate, _ rhs: SuggestionCandidate, otherwise: Bool) -> Bool {
        if lhs.lastUsed != rhs.lastUsed { return (lhs.lastUsed ?? .distantPast) > (rhs.lastUsed ?? .distantPast) }
        if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
        return otherwise
    }

    /// The candidates that match `words` (already folded), closest first, then most recent, then most used; the
    /// given order breaks the remaining ties.
    private static func ordered(_ candidates: [SuggestionCandidate], matching words: String) -> [SuggestionCandidate] {
        typealias Ranked = (candidate: SuggestionCandidate, match: Match, index: Int)
        let ranked: [Ranked] = candidates.enumerated().compactMap { index, candidate in
            match(words, candidate).map { (candidate, $0, index) }
        }
        return ranked.sorted { (lhs: Ranked, rhs: Ranked) -> Bool in
            lhs.match != rhs.match
                ? lhs.match < rhs.match : comesFirst(lhs.candidate, rhs.candidate, otherwise: lhs.index < rhs.index)
        }
        .map(\.candidate)
    }

    static func match(_ words: String, _ candidate: SuggestionCandidate) -> Match? {
        var host = fold(candidate.url.host() ?? "")
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix(words) { return .hostPrefix }
        let title = fold(candidate.title)
        if startsAWord(words, in: title) { return .titleWordPrefix }
        let address = candidate.url.absoluteString
        if title.contains(words) || fold(address.removingPercentEncoding ?? address).contains(words) {
            return .substring
        }
        return nil
    }

    /// `words` occurs in `text` at its start or right after a character that is no letter or digit.
    private static func startsAWord(_ words: String, in text: String) -> Bool {
        var from = text.startIndex
        while let found = text.range(of: words, range: from..<text.endIndex) {
            if found.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: found.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The list's state for one field; local sources only. `history` is a HistorySource (nil for Anonymous).
@MainActor @Observable public final class SuggestionModel {
    public typealias LocalSources = @MainActor () -> (openTabs: [SuggestionCandidate], bookmarks: [SuggestionCandidate])

    /// How long typing must pause before history is read.
    static let debounce = Duration.milliseconds(100)
    /// Visits read per history search; they fold to fewer pages.
    static let historyVisits = 200

    public private(set) var rows: [Suggestion] = []
    /// The row Return opens; nil opens what was typed.
    public var highlighted: Int?
    /// The words `rows` are for, as typed.
    public private(set) var words = ""
    /// The address `words` complete to from this field's candidates (history included once read), longer than
    /// `words`; nil when they complete to none.
    public private(set) var completion: String?

    @ObservationIgnored private let history: (any HistorySource)?
    @ObservationIgnored private let local: LocalSources
    @ObservationIgnored private let engine: @MainActor () -> SearchEngine
    @ObservationIgnored private let delay: Duration
    /// The last history read's pages; ranked again for later words until the next read replaces them.
    @ObservationIgnored private var historyCandidates: [SuggestionCandidate] = []
    @ObservationIgnored private(set) var historyRead: Task<Void, Never>?

    public convenience init(
        history: (any HistorySource)?,
        local: @escaping LocalSources, engine: @escaping @MainActor () -> SearchEngine
    ) {
        self.init(history: history, local: local, engine: engine, debounce: Self.debounce)
    }

    init(
        history: (any HistorySource)?,
        local: @escaping LocalSources, engine: @escaping @MainActor () -> SearchEngine, debounce: Duration
    ) {
        self.history = history
        self.local = local
        self.engine = engine
        delay = debounce
    }

    /// Ranks and completes `typed` from the local sources and the last history read at once, then reads history for
    /// it once typing pauses; a newer `update` or `dismiss` drops a read under way. Blank text empties the list.
    /// Never touches the network.
    public func update(_ typed: String) {
        words = typed
        highlighted = nil
        historyRead?.cancel()
        historyRead = nil
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            rows = []
            completion = nil
            return
        }
        rank()
        guard let history else { return }
        historyRead = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let visits = (try? await history.search(query, limit: Self.historyVisits)) ?? []
            guard !Task.isCancelled, let self else { return }
            historyCandidates = SuggestionRanker.candidates(from: visits)
            rank()
        }
    }

    /// Highlights the row above; from the first row, none, so Return opens what was typed.
    public func moveUp() {
        guard let highlighted else { return }
        self.highlighted = highlighted > 0 ? highlighted - 1 : nil
    }

    /// Highlights the row below, the first one when none is; the last row stays.
    public func moveDown() {
        guard !rows.isEmpty else { return }
        highlighted = min((highlighted ?? -1) + 1, rows.count - 1)
    }

    /// Closes the list and drops the completion; the next `update` opens and completes again.
    public func dismiss() {
        historyRead?.cancel()
        historyRead = nil
        rows = []
        highlighted = nil
        completion = nil
    }

    /// Ranks for `words` again, and completes them; a highlighted row still listed stays highlighted.
    private func rank() {
        let kept = highlighted.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        let sources = local()
        rows = SuggestionRanker.rank(
            words: words, engine: engine(), openTabs: sources.openTabs, bookmarks: sources.bookmarks,
            history: historyCandidates)
        highlighted = kept.flatMap { rows.firstIndex(of: $0) }
        completion = SuggestionRanker.completion(
            for: words, among: sources.openTabs + sources.bookmarks + historyCandidates)
    }
}
