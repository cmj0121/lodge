import Foundation
import Testing

@testable import LodgeKit

@Suite struct HistoryDayTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func visit(_ id: Int64, _ at: Date) -> HistoryVisit {
        HistoryVisit(id: id, url: URL(string: "https://\(id).example/")!, title: "\(id)", visitedAt: at)
    }

    @Test func groupsIntoTodayYesterdayAndDatesNewestFirst() {
        let now = date(13, 9)
        let visits = [
            visit(6, date(13, 8)), visit(5, date(13, 0)), visit(4, date(12, 23)), visit(3, date(12, 1)),
            visit(2, date(10, 12)), visit(1, date(9, 12)),
        ]
        let days = HistoryDay.group(visits, calendar: calendar, now: now)
        #expect(days.map(\.id) == [date(13, 0), date(12, 0), date(10, 0), date(9, 0)])
        #expect(days.map { $0.visits.map(\.id) } == [[6, 5], [4, 3], [2], [1]])
        var format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        #expect(days.map(\.title) == ["Today", "Yesterday", date(10, 0).formatted(format), date(9, 0).formatted(format)])
    }

    @Test func daysFollowTheCalendarTimeZone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 01:00 on the 13th in Taipei is still the 12th in UTC.
        let days = HistoryDay.group([visit(1, date(13, 1))], calendar: utc, now: date(13, 9))
        #expect(days.map(\.title) == ["Yesterday"])
    }

    @Test func noVisitsMeansNoDays() {
        #expect(HistoryDay.group([], calendar: calendar, now: date(13, 9)).isEmpty)
    }
}
