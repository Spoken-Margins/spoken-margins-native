import Foundation
import XCTest
@testable import SessionKit

/// Pace words counted from catalog publish dates (#4285, PR 2).
final class CatalogPackPaceTests: XCTestCase {
    private let asOf = Date(timeIntervalSince1970: 1_794_000_000)
    private let day: TimeInterval = 86_400

    private func dates(daysBefore: [Double]) -> [Date] { daysBefore.map { asOf.addingTimeInterval(-$0 * day) } }

    private func measure(_ daysBefore: [Double]) -> CatalogPackPace.Measure? {
        CatalogPackPace.measure(recentPublishedDates: dates(daysBefore: daysBefore), asOf: asOf)
    }

    private func row(_ daysBefore: [Double]) -> String? { CatalogPackPace.rowWords(measure(daysBefore)) }

    /// `count` dates evenly over the last 56 days, newest at 0.
    private func evenly(_ count: Int) -> [Double] { (0..<count).map { Double($0) * 55 / Double(max(1, count - 1)) } }

    // MARK: Rate

    func testFewerThanTwoDatesAreUnknown() {
        XCTAssertNil(measure([]))
        XCTAssertNil(measure([1]))
        XCTAssertNil(CatalogPackPace.measure(recentPublishedDates: dates(daysBefore: [1, 2, 3]), asOf: nil), "no as-of moment")
        // Dates after the as-of moment are not kept, so two of three leave one.
        XCTAssertNil(measure([-1, -2, 3]))
        XCTAssertNil(measure([0, -5]))
        XCTAssertEqual(CatalogPackPace.rowWords(nil), nil)
        XCTAssertEqual(CatalogPackPace.packWords(nil), "Pace not known yet")
    }

    func testTwoDatesOnTheSameDayStillCountOverAWeekAtLeast() throws {
        let rate = try XCTUnwrap(measure([3, 3])).itemsPerWeek
        XCTAssertEqual(rate, 2, accuracy: 1e-9, "2 items over the 7-day minimum window")
        XCTAssertEqual(try XCTUnwrap(measure([0, 0])).itemsPerWeek, 2, accuracy: 1e-9)
    }

    func testTheWindowStartsAtTheOldestDateWhenThatIsWithinFiftySixDays() throws {
        // Oldest 28 days back: window 28 days, 5 items in it -> 5 * 7 / 28 = 1.25.
        XCTAssertEqual(try XCTUnwrap(measure([0, 7, 14, 21, 28])).itemsPerWeek, 1.25, accuracy: 1e-9)
    }

    func testDatesOlderThanFiftySixDaysFallOutOfTheWindow() throws {
        // Window is the last 56 days: 3 items in it (0, 28, 56) -> 3 * 7 / 56 = 0.375; the one at 100 days is outside.
        XCTAssertEqual(try XCTUnwrap(measure([0, 28, 56, 100])).itemsPerWeek, 0.375, accuracy: 1e-9)
        // Just inside and just outside the edge.
        XCTAssertEqual(try XCTUnwrap(measure([0, 55.99])).itemsPerWeek, 2.0 * 7 / 55.99, accuracy: 1e-9, "the oldest date starts the window")
        XCTAssertEqual(try XCTUnwrap(measure([0, 56.01])).itemsPerWeek, 1.0 * 7 / 56, accuracy: 1e-9)
    }

    func testTwentyDailyDatesRead() throws {
        // Oldest 19 days back: 20 items over 19 days -> 7.37 a week.
        let daily = (0..<20).map(Double.init)
        XCTAssertEqual(try XCTUnwrap(measure(daily)).itemsPerWeek, 20.0 * 7 / 19, accuracy: 1e-9)
        XCTAssertEqual(row(daily), "About one a day")
    }

    func testDatesAreReadInAnyOrder() {
        XCTAssertEqual(measure([21, 0, 14, 7, 28]), measure([0, 7, 14, 21, 28]))
    }

    // MARK: Words

    /// The ladder at and either side of every boundary, given as items per week through a window of exactly 7 days.
    func testEveryBoundaryOfTheLadder() {
        func words(_ rate: Double, stale: Bool = false) -> (pack: String, row: String?) {
            let measure = CatalogPackPace.Measure(itemsPerWeek: rate, newestIsStale: stale)
            return (CatalogPackPace.packWords(measure), CatalogPackPace.rowWords(measure))
        }
        let table: [(Double, String, String)] = [
            (0.0, "Now and then", "Now and then"),
            (0.1999, "Now and then", "Now and then"),
            (0.2, "About one new a month", "About one a month"),
            (0.5, "About 2 new a month", "About 2 a month"),
            (0.7499, "About 3 new a month", "About 3 a month"),
            (0.75, "About one new a week", "About one a week"),
            (1.0, "About one new a week", "About one a week"),
            (1.4999, "About one new a week", "About one a week"),
            (1.5, "About 2 new a week", "About 2 a week"),
            (3.0, "About 3 new a week", "About 3 a week"),
            (6.4999, "About 6 new a week", "About 6 a week"),
            (6.5, "About one new a day", "About one a day"),
            (7.0, "About one new a day", "About one a day"),
            (10.4999, "About one new a day", "About one a day"),
            (10.5, "About 2 new a day", "About 2 a day"),
            (14.0, "About 2 new a day", "About 2 a day"),
            (21.0, "About 3 new a day", "About 3 a day"),
        ]
        for (rate, pack, row) in table {
            let result = words(rate)
            XCTAssertEqual(result.pack, pack, "\(rate) a week, pack")
            XCTAssertEqual(result.row, row, "\(rate) a week, row")
        }
        XCTAssertEqual(words(5, stale: true).pack, "Now and then", "a source whose newest item is over 90 days old is now and then, whatever its rate")
        XCTAssertEqual(words(5, stale: true).row, "Now and then")
    }

    func testANewestDateOverNinetyDaysOldReadsNowAndThen() {
        XCTAssertEqual(row([91, 92, 93, 94]), "Now and then")
        XCTAssertEqual(measure([91, 92])?.newestIsStale, true)
        XCTAssertEqual(measure([90, 91])?.newestIsStale, false, "exactly 90 days is not over 90")
        XCTAssertEqual(measure([89.9, 100])?.newestIsStale, false)
    }

    func testRealisticFeeds() {
        XCTAssertEqual(row(evenly(20)), "About 3 a week", "20 items over 55 days is 2.5 a week")
        XCTAssertEqual(row([0, 30]), "About 2 a month", "2 items over 30 days is 0.47 a week")
        XCTAssertEqual(row([0, 1, 2, 3, 4, 5, 6, 7]), "About one a day", "8 items over 7 days")
        XCTAssertEqual(row([0, 2, 4, 6, 8, 10, 12, 14]), "About 4 a week", "8 items over 14 days")
        XCTAssertEqual(row([3, 40]), "About 2 a month")
    }

    // MARK: A pack

    func testAPackAddsTheKnownRatesAndIsUnknownWhenFewerThanHalfAreKnown() throws {
        let a = CatalogPackPace.Measure(itemsPerWeek: 7, newestIsStale: false)
        let b = CatalogPackPace.Measure(itemsPerWeek: 3.5, newestIsStale: false)
        XCTAssertEqual(try XCTUnwrap(CatalogPackPace.packMeasure([a, b, nil])).itemsPerWeek, 10.5, accuracy: 1e-9)
        XCTAssertEqual(CatalogPackPace.packWords(CatalogPackPace.packMeasure([a, b, nil])), "About 2 new a day")
        XCTAssertNotNil(CatalogPackPace.packMeasure([a, nil]), "exactly half known is enough")
        XCTAssertNil(CatalogPackPace.packMeasure([a, nil, nil]))
        XCTAssertNil(CatalogPackPace.packMeasure([nil, nil]))
        XCTAssertNil(CatalogPackPace.packMeasure([]))
        let stale = CatalogPackPace.Measure(itemsPerWeek: 4, newestIsStale: true)
        XCTAssertEqual(CatalogPackPace.packMeasure([stale, stale])?.newestIsStale, true)
        XCTAssertEqual(CatalogPackPace.packMeasure([stale, a])?.newestIsStale, false, "stale only when every known source is")
    }

    func testAnEntrysRateIsCountedAsOfTheCatalogsGeneratedAt() throws {
        var entry = SourceCatalogEntry(id: "a", kind: .podcastFeed, contentKind: .podcast, title: "A", feedURL: "https://f.example/a.xml", subjects: ["s"], provenanceIds: ["p"])
        entry.recentPublishedAt = ["2026-11-14T08:00:00Z", "2026-11-07T08:00:00Z", "2026-10-31T08:00:00Z", "nonsense"]
        var catalog = SourceCatalog(schemaVersion: SourceCatalog.currentSchemaVersion, catalogId: "c", contentVersion: 1, title: "C", generatedAt: "2026-11-14T12:00:00Z", locale: nil, provenance: [], subjects: [], starterRows: nil, packs: nil, entries: [entry])
        let measured = try XCTUnwrap(CatalogPackPace.measure(for: entry, in: catalog))
        // 3 dates over 14.17 days (oldest 2026-10-31T08:00 to as-of 2026-11-14T12:00) -> about 1.48 a week.
        XCTAssertEqual(measured.itemsPerWeek, 3.0 * 7 / (14 + 4.0 / 24), accuracy: 1e-6)
        XCTAssertEqual(CatalogPackPace.rowWords(measured), "About one a week")
        catalog.generatedAt = "not a time"
        XCTAssertNil(CatalogPackPace.measure(for: entry, in: catalog), "an unparseable generatedAt leaves every pace unknown")
    }
}
