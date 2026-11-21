import XCTest
@testable import SessionKit

final class DiskWriteLedgerTests: XCTestCase {
    private static func parse(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func date(_ iso: String) -> Date { Self.parse(iso) }

    func testBytesAddUpBySourceWithinOneUTCDay() {
        var ledger = DiskWriteLedger()
        ledger.record(bytes: 2_000_000_000, source: .download, at: date("2026-11-18T01:00:00Z"))
        ledger.record(bytes: 900_000_000, source: .speechRender, at: date("2026-11-18T23:59:59Z"))
        ledger.record(bytes: 900_000_000, source: .speechAssembly, at: date("2026-11-18T12:00:00Z"))
        ledger.record(bytes: 500_000_000, source: .download, at: date("2026-11-18T12:00:00Z"))

        XCTAssertEqual(ledger.summaryText,
                       "2026-11-18 total=4300MB download=2500MB speech_assembly=900MB speech_render=900MB; counted=download,speech_render,speech_assembly")
    }

    func testAWriteJustAfterMidnightUTCStartsANewDayNewestFirst() {
        var ledger = DiskWriteLedger()
        ledger.record(bytes: 1_000_000, source: .download, at: date("2026-11-18T23:59:59Z"))
        ledger.record(bytes: 2_000_000, source: .download, at: date("2026-11-19T00:00:00Z"))

        XCTAssertTrue(ledger.summaryText.hasPrefix("2026-11-19 total=2MB download=2MB; 2026-11-18 total=1MB download=1MB; counted="), ledger.summaryText)
    }

    func testNeighbouringSizesRoundToWholeMegabytesAndASmallWriteIsNeverZero() {
        XCTAssertEqual(DiskWriteLedger.megabytes(0), 0)
        XCTAssertEqual(DiskWriteLedger.megabytes(1), 1, "a write that happened shows")
        XCTAssertEqual(DiskWriteLedger.megabytes(499_999), 1)
        XCTAssertEqual(DiskWriteLedger.megabytes(1_499_999), 1)
        XCTAssertEqual(DiskWriteLedger.megabytes(1_500_000), 2)
        XCTAssertEqual(DiskWriteLedger.megabytes(4_300_000_000), 4300)
    }

    func testEmptyZeroAndNegativeWritesCountNothing() {
        var ledger = DiskWriteLedger()
        ledger.record(bytes: 0, source: .download, at: Date())
        ledger.record(bytes: -5, source: .download, at: Date())

        XCTAssertEqual(ledger, DiskWriteLedger())
        XCTAssertTrue(ledger.summaryText.hasPrefix("none_recorded; counted="))
    }

    func testOnlyTheNewestFourteenDaysAreKeptAndSevenAreNamed() {
        var ledger = DiskWriteLedger()
        let start = date("2026-11-01T12:00:00Z")
        for offset in 0..<20 {
            ledger.record(bytes: 1_000_000, source: .download, at: start.addingTimeInterval(TimeInterval(offset) * 86_400))
        }

        XCTAssertEqual(ledger.days.count, DiskWriteLedger.keptDays)
        XCTAssertNil(ledger.days["2026-11-01"])
        XCTAssertNotNil(ledger.days["2026-11-20"])
        XCTAssertEqual(ledger.summaryText.components(separatedBy: "; ").count, DiskWriteLedger.summaryDays + 1, "seven days and the counted line")
    }

    func testKeysThatAreNotDaysNeverPushRealDaysOutOfTheLedger() {
        // Fourteen odd keys that sort after every digit: pruned by sort order alone, each new real day would go at once.
        var odd: [String: [String: Int64]] = [:]
        for index in 0..<14 { odd["my diary \(index)"] = ["download": 1] }
        var ledger = DiskWriteLedger(days: odd)

        ledger.record(bytes: 2_000_000, source: .download, at: date("2026-11-18T10:00:00Z"))

        XCTAssertEqual(Array(ledger.days.keys), ["2026-11-18"])
        XCTAssertTrue(ledger.summaryText.hasPrefix("2026-11-18 total=2MB download=2MB;"), ledger.summaryText)
    }

    func testADayAfterTodayLeftByAClockSetAheadIsDroppedOnTheNextWrite() {
        var ledger = DiskWriteLedger()
        ledger.record(bytes: 9_000_000, source: .download, at: date("2027-03-01T10:00:00Z"))
        ledger.record(bytes: 1_000_000, source: .download, at: date("2026-11-18T10:00:00Z"))

        XCTAssertNil(ledger.days["2027-03-01"], "the bogus future day is gone")
        XCTAssertTrue(ledger.summaryText.hasPrefix("2026-11-18 total=1MB download=1MB; counted="), ledger.summaryText)
    }

    func testTodayAndEarlierDaysSurviveAWriteLaterTheSameDay() {
        var ledger = DiskWriteLedger()
        ledger.record(bytes: 1_000_000, source: .download, at: date("2026-11-17T23:00:00Z"))
        ledger.record(bytes: 1_000_000, source: .download, at: date("2026-11-18T01:00:00Z"))
        ledger.record(bytes: 1_000_000, source: .speechRender, at: date("2026-11-18T23:00:00Z"))

        XCTAssertEqual(Set(ledger.days.keys), ["2026-11-17", "2026-11-18"])
    }

    func testTheSummaryHoldsSourceNamesDaysAndMegabytesOnly() {
        var ledger = DiskWriteLedger()
        for source in DiskWriteLedger.Source.allCases { ledger.record(bytes: 7_000_000, source: source, at: date("2026-11-18T10:00:00Z")) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_=,;: ")

        XCTAssertTrue(ledger.summaryText.allSatisfy { allowed.contains($0) || $0 == "M" || $0 == "B" }, ledger.summaryText)
    }

    func testWhateverAFileHoldsOnlyDaysAndSourceNamesOfTheShapesWeWriteAreSummarised() throws {
        let file = try temporaryFile()
        try Data(#"{"days":{"2026-11-18":{"download":4000000,"My Secret Diary.pdf":9000000,"Upper":1,"":2},"my diary":{"download":5},"2026-11-17x":{"download":5}}}"#.utf8).write(to: file)

        let store = DiskWriteLedgerStore(fileURL: file, now: { Self.parse("2026-11-18T12:00:00Z") })

        XCTAssertEqual(store.summaryText, "2026-11-18 total=4MB download=4MB; counted=download,speech_render,speech_assembly")
    }

    // MARK: The file

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskWriteLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("disk-writes.json")
    }

    func testTheStoreKeepsWhatAnEarlierLaunchWrote() throws {
        let file = try temporaryFile()
        let noon = date("2026-11-18T12:00:00Z")
        let first = DiskWriteLedgerStore(fileURL: file, now: { noon })
        first.record(bytes: 3_000_000_000, source: .download)

        let second = DiskWriteLedgerStore(fileURL: file, now: { noon })
        second.record(bytes: 1_000_000_000, source: .speechRender)

        XCTAssertTrue(second.summaryText.hasPrefix("2026-11-18 total=4000MB download=3000MB speech_render=1000MB;"), second.summaryText)
        XCTAssertEqual(DiskWriteLedgerStore(fileURL: file, now: { noon }).summaryText, second.summaryText)
    }

    func testTheStoreSizesARealFileAndIgnoresAMissingOne() throws {
        let file = try temporaryFile()
        let counted = file.deletingLastPathComponent().appendingPathComponent("chunk.wav")
        try Data(count: 2_500_000).write(to: counted)
        let store = DiskWriteLedgerStore(fileURL: file, now: { Self.parse("2026-11-18T12:00:00Z") })

        store.record(fileAt: counted, source: .speechRender)
        store.record(fileAt: file.deletingLastPathComponent().appendingPathComponent("gone.wav"), source: .speechRender)

        XCTAssertTrue(store.summaryText.hasPrefix("2026-11-18 total=3MB speech_render=3MB;"), store.summaryText)
    }

    func testAnUnreadableFileStartsEmptyAndAnUnwritablePathStillCounts() throws {
        let file = try temporaryFile()
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(DiskWriteLedgerStore(fileURL: file).summaryText.hasPrefix("none_recorded"))

        let nowhere = file.deletingLastPathComponent().appendingPathComponent("no/such/folder/disk-writes.json")
        let store = DiskWriteLedgerStore(fileURL: nowhere, now: { Self.parse("2026-11-18T12:00:00Z") })
        store.record(bytes: 5_000_000, source: .download)
        XCTAssertTrue(store.summaryText.hasPrefix("2026-11-18 total=5MB"), "counting a write never fails the write it counts")
    }

    func testAFileWrittenByABuildWithAnotherSourceStillLoads() throws {
        let file = try temporaryFile()
        try Data(#"{"days":{"2026-11-18":{"download":4000000,"database":9000000}}}"#.utf8).write(to: file)

        let store = DiskWriteLedgerStore(fileURL: file, now: { Self.parse("2026-11-18T12:00:00Z") })

        XCTAssertTrue(store.summaryText.hasPrefix("2026-11-18 total=13MB database=9MB download=4MB;"), store.summaryText)
    }
}
