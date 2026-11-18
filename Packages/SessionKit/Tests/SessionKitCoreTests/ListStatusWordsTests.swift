import XCTest
@testable import SessionKit

/// #4046: the shared time words for lists and rules.
final class ListStatusWordsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }
    private let locale = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func words(_ date: Date, now: Date) -> String {
        ListStatusWords.time(date, now: now, calendar: calendar, locale: locale)
    }

    func testToday() {
        let now = date(2026, 11, 18, 14, 30)
        XCTAssertTrue(words(date(2026, 11, 18, 9, 5), now: now).hasPrefix("today at 9:05"))
        XCTAssertTrue(words(date(2026, 11, 18, 14, 30), now: now).hasPrefix("today at 2:30"))
        XCTAssertTrue(words(date(2026, 11, 18, 0, 0), now: now).hasPrefix("today at 12:00"), "midnight is today, not yesterday")
    }

    func testYesterdayIsTheCalendarDayBeforeNotTwentyFourHours() {
        let now = date(2026, 11, 18, 0, 10)
        XCTAssertTrue(words(date(2026, 11, 17, 23, 55), now: now).hasPrefix("yesterday at 11:55"))
        XCTAssertEqual(words(date(2026, 11, 16, 23, 55), now: now), "Nov 16")
    }

    func testOlderDatesAreMonthAndDay() {
        let now = date(2026, 11, 18, 14, 30)
        XCTAssertEqual(words(date(2026, 11, 13, 8), now: now), "Nov 13")
        XCTAssertEqual(words(date(2026, 1, 2, 8), now: now), "Jan 2")
    }

    func testADifferentYearCarriesTheYear() {
        let now = date(2026, 1, 3, 12)
        XCTAssertEqual(words(date(2025, 11, 13, 8), now: now), "Nov 13, 2025")
        XCTAssertEqual(words(date(2025, 12, 31, 8), now: now), "Dec 31, 2025", "two days back across New Year is not yesterday")
        XCTAssertTrue(words(date(2026, 1, 2, 8), now: now).hasPrefix("yesterday at"), "yesterday across New Year's Eve")
    }

    func testAFutureDateIsStillAPlainDate() {
        XCTAssertEqual(words(date(2026, 11, 20, 8), now: date(2026, 11, 18, 14)), "Nov 20")
    }
}
