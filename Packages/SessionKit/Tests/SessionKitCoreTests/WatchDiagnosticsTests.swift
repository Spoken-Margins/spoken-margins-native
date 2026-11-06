import Foundation
import XCTest
@testable import SessionKit

/// #3506: the Watch keeps a small record of launches, failures and unclean endings, with no Margin text, and sends it
/// to the phone, which keeps the latest copy for its Diagnostics export.
final class WatchDiagnosticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func kinds(_ log: WatchDiagnosticsLog) -> [String] { log.events.map(\.kind.rawValue) }

    // MARK: How the last run ended

    func testAFirstLaunchRecordsOnlyTheLaunch() {
        var log = WatchDiagnosticsLog()
        log.launched(at: t0)
        XCTAssertEqual(kinds(log), ["launched"])
        XCTAssertEqual(log.launchCount, 1)
    }

    /// The owner's case: the app closes at once on every launch. Each launch dies before the front, and the next one
    /// says so.
    func testALaunchThatNeverReachedTheFrontIsNamedOnTheNextLaunch() {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        log.launched(at: at(10))
        log.launched(at: at(20))
        XCTAssertEqual(kinds(log), ["launched", "previousLaunchNeverBecameActive", "launched",
                                    "previousLaunchNeverBecameActive", "launched"])
        XCTAssertEqual(log.launchCount, 3)
    }

    func testARunThatEndedInFrontIsNamedAndOneThatWentToTheBackgroundIsNot() {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        log.becameActive(at: at(1))
        log.launched(at: at(100)) // ended while in front
        XCTAssertTrue(kinds(log).contains("previousRunEndedInFront"))

        var clean = WatchDiagnosticsLog()
        clean.launched(at: at(0))
        clean.becameActive(at: at(1))
        clean.wentToBackground()
        clean.launched(at: at(100))
        XCTAssertEqual(kinds(clean), ["launched", "becameActive", "launched"])
    }

    /// A WatchConnectivity wake in the background never comes to the front; it must not read as a launch crash.
    func testABackgroundWakeIsNotALaunchCrash() {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0), inFront: false)
        log.launched(at: at(60))
        XCTAssertFalse(kinds(log).contains("previousLaunchNeverBecameActive"))
    }

    /// Wrist raises are not events: only the first time in front after a launch is.
    func testBecameActiveIsRecordedOncePerLaunch() {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        for second in 1...5 {
            log.becameActive(at: at(Double(second) * 10))
            log.wentToBackground()
        }
        XCTAssertEqual(kinds(log).filter { $0 == "becameActive" }.count, 1)
        log.launched(at: at(100))
        log.becameActive(at: at(101))
        XCTAssertEqual(kinds(log).filter { $0 == "becameActive" }.count, 2)
    }

    // MARK: Format and size

    func testTheRecordKeepsTheLastFortyEvents() {
        var log = WatchDiagnosticsLog()
        for i in 0..<100 { log.failed("transferFailed", detail: "D/\(i)", at: at(Double(i))) }
        XCTAssertEqual(log.events.count, WatchDiagnosticsLog.maxEvents)
        XCTAssertEqual(log.events.last?.number, 100)
        XCTAssertEqual(log.events.first?.number, 61)
    }

    func testTheEncodedRecordStaysUnderItsByteLimitEvenWithLongDetails() throws {
        var log = WatchDiagnosticsLog()
        for i in 0..<200 {
            log.failed(String(repeating: "x", count: 500), detail: String(repeating: "y", count: 500), at: at(Double(i)))
        }
        let size = try WatchDiagnosticsCoding.encoder.encode(log).count
        XCTAssertLessThanOrEqual(size, WatchDiagnosticsLog.maxEncodedBytes)
        XCTAssertFalse(log.events.isEmpty)
        XCTAssertTrue(log.events.allSatisfy { $0.detail.count <= WatchDiagnosticsLog.maxDetailLength })
    }

    func testTheRecordRoundTripsThroughItsFormat() throws {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        log.becameActive(at: at(1))
        log.failed("transferFailed", detail: "WCErrorDomain/7014", at: at(2))
        let data = try WatchDiagnosticsCoding.encoder.encode(log)
        let back = try WatchDiagnosticsCoding.decoder.decode(WatchDiagnosticsLog.self, from: data)
        XCTAssertEqual(back, log)
    }

    // MARK: What may go in (a table of neighbouring inputs)

    func testDetailKeepsOnlyPlainShortText() {
        let rows: [(input: String, expected: String)] = [
            ("NSCocoaErrorDomain/513", "NSCocoaErrorDomain/513"),
            ("", ""),
            ("  spaces  kept  ", "  spaces  kept  "),
            ("line one\nline two", "line oneline two"),
            ("quote \"marked\" [text] (here)", "quote marked text here"),
            ("café résumé", "caf rsum"),
            ("see https://example.com/a/b?q=1 now", "see https:example.comabq=1 now"),
            ("/private/var/mobile/Containers/x.m4a", "privatevarmobileContainersx.m4a"),
            ("Domain/513", "Domain/513"),
            ("日本語", ""),
        ]
        for row in rows {
            XCTAssertEqual(WatchDiagnosticsLog.cleaned(row.input), row.expected, "input: \(row.input)")
        }
        XCTAssertEqual(WatchDiagnosticsLog.cleaned(String(repeating: "a", count: 1_000)).count, WatchDiagnosticsLog.maxDetailLength)
    }

    func testErrorCodeIsDomainAndCodeOnly() {
        let error = NSError(domain: "WCErrorDomain", code: 7014, userInfo: [NSLocalizedDescriptionKey: "Margin text the listener said"])
        XCTAssertEqual(WatchDiagnosticsLog.errorCode(error), "WCErrorDomain/7014")
    }

    // MARK: Sending

    func testHasUnsentUntilMarkedSentAndAgainAfterANewEvent() {
        var log = WatchDiagnosticsLog()
        XCTAssertFalse(log.hasUnsent)
        log.launched(at: at(0))
        XCTAssertTrue(log.hasUnsent)
        log.markSent()
        XCTAssertFalse(log.hasUnsent)
        log.becameActive(at: at(1))
        XCTAssertTrue(log.hasUnsent)
    }

    func testTheDiagnosticsMessageSurvivesTheEnvelope() throws {
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        let report = log.report(build: "36", osVersion: "26.1", at: at(5))
        let envelope = WatchEnvelope(seq: 3, sentAt: at(5), clock: nil, message: .diagnostics(report))
        let back = try XCTUnwrap(WatchEnvelope(dictionary: envelope.dictionary))
        XCTAssertEqual(back.message, .diagnostics(report))
    }

    /// A Watch build that adds a new kind of event must still be readable by this phone.
    func testAnUnknownEventKindStillDecodes() throws {
        let json = #"{"number":1,"at":1800000000,"kind":"somethingNew","detail":"x"}"#
        let event = try WatchDiagnosticsCoding.decoder.decode(WatchDiagnosticEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.kind.rawValue, "somethingNew")
    }

    // MARK: The Watch's file

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("watch-diagnostics-\(UUID().uuidString).json")
    }

    func testTheRecorderWritesEachChangeSoALaterLaunchCanReadIt() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        WatchDiagnosticsRecorder(fileURL: file).update { $0.launched(at: self.at(0)) }
        // The process "crashed" here: a new recorder, as a new launch has.
        let next = WatchDiagnosticsRecorder(fileURL: file)
        next.update { $0.launched(at: self.at(30)) }
        XCTAssertEqual(kinds(next.load()), ["launched", "previousLaunchNeverBecameActive", "launched"])
    }

    func testACorruptFileStartsAFreshLog() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let recorder = WatchDiagnosticsRecorder(fileURL: file)
        XCTAssertTrue(recorder.load().events.isEmpty)
        recorder.update { $0.launched(at: self.at(0)) }
        XCTAssertEqual(kinds(recorder.load()), ["launched"])
    }

    func testARecorderWithNoFileKeepsNothingOnDisk() {
        let recorder = WatchDiagnosticsRecorder(fileURL: nil)
        recorder.update { $0.launched(at: self.at(0)) }
        XCTAssertTrue(recorder.load().events.isEmpty)
    }

    // MARK: The phone's copy

    func testThePhoneKeepsTheLatestReportAndIgnoresAnOlderOne() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))
        let older = log.report(build: "36", osVersion: "26.1", at: at(1))
        log.becameActive(at: at(2))
        let newer = log.report(build: "36", osVersion: "26.1", at: at(3))

        XCTAssertTrue(WatchDiagnosticsStore.save(newer, to: file))
        XCTAssertFalse(WatchDiagnosticsStore.save(older, to: file), "the sure lane can arrive late")
        XCTAssertEqual(WatchDiagnosticsStore.read(file)?.events.count, 2)
    }

    func testThePhoneCutsAnOversizedOrHandMadeReportToTheWatchLimits() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let events = (1...500).map {
            WatchDiagnosticEvent(number: $0, at: at(Double($0)), kind: .failure, detail: String(repeating: "z", count: 400))
        }
        let report = WatchDiagnosticsReport(build: String(repeating: "b", count: 300), osVersion: "26.1", sentAt: at(1),
                                            launchCount: 9, phase: .active, events: events)
        WatchDiagnosticsStore.save(report, to: file)
        let kept = try XCTUnwrap(WatchDiagnosticsStore.read(file))
        XCTAssertLessThanOrEqual(kept.events.count, WatchDiagnosticsLog.maxEvents)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, WatchDiagnosticsLog.maxEncodedBytes)
        XCTAssertTrue(kept.events.allSatisfy { $0.detail.count <= WatchDiagnosticsLog.maxDetailLength })
        XCTAssertEqual(kept.build.count, WatchDiagnosticsLog.maxDetailLength)
    }

    /// Done when 3: a launch that crashed is visible in the export after a later launch that survived.
    func testTheExportShowsACrashedLaunchAfterALaterLaunchSurvived() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var log = WatchDiagnosticsLog()
        log.launched(at: at(0))               // crashed before the front
        log.launched(at: at(60))              // survived
        log.becameActive(at: at(61))
        WatchDiagnosticsStore.save(log.report(build: "36", osVersion: "26.1", at: at(62)), to: file)

        let text = try XCTUnwrap(WatchDiagnosticsStore.exportJSON(fileURL: file))
        XCTAssertTrue(text.contains("previousLaunchNeverBecameActive"))
        XCTAssertTrue(text.contains(WatchDiagnosticsStore.schemaVersion))
        XCTAssertTrue(text.contains("2027-01-15"), "dates read as ISO 8601 in the export")
        XCTAssertNil(WatchDiagnosticsStore.exportJSON(fileURL: temporaryFile()), "no report, no entry")
    }
}
