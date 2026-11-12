import Foundation

/// Day sections for the window, newest first: "Today", "Yesterday", then the date (`.abbreviated`).
public struct HistoryDay: Identifiable, Equatable, Sendable {
    /// The start of the day in the calendar it was grouped with.
    public let id: Date
    public let title: String
    public let visits: [HistoryVisit]

    /// Groups `visits` by the day they happened in `calendar`, keeping their order within a day.
    public static func group(_ visits: [HistoryVisit], calendar: Calendar, now: Date) -> [HistoryDay] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        var format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        return Dictionary(grouping: visits) { calendar.startOfDay(for: $0.visitedAt) }
            .sorted { $0.key > $1.key }
            .map { day, visits in
                let title =
                    switch day {
                    case today: "Today"
                    case yesterday: "Yesterday"
                    default: day.formatted(format)
                    }
                return HistoryDay(id: day, title: title, visits: visits)
            }
    }
}
