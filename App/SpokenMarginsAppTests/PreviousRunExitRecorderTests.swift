import XCTest
import SessionKit
@testable import SpokenMarginsApp

#if canImport(MetricKit)
/// #1682: the 4 stops in #1679 had to be inferred from gaps in the log.
@MainActor
final class PreviousRunExitRecorderTests: XCTestCase {
    private var events: [(kind: String, fields: [String: String])] = []
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "previous-run-exit-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let cpuException = Data("""
    { "timeStampBegin" : "2026-10-15 09:00:00", "timeStampEnd" : "2026-10-16 09:00:00",
      "cpuExceptionDiagnostics" : [ { "diagnosticMetaData" : { "totalCPUTime" : "92 sec", "totalSampledTime" : "300 sec" } } ] }
    """.utf8)

    private func makeRecorder() -> PreviousRunExitRecorder {
        let recorder = PreviousRunExitRecorder(defaults: defaults)
        recorder.attach { [unowned self] kind, fields in self.events.append((kind, fields)) }
        return recorder
    }

    func testLaunchWritesOneEventNamingTheReasonAndASecondLaunchDoesNotRepeatIt() {
        let first = makeRecorder()
        first.deliver(diagnostics: [cpuException], metrics: [], isLaunch: true)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, "app.previous_exit")
        XCTAssertEqual(events[0].fields["reason"], "cpu_exception")
        XCTAssertEqual(events[0].fields["delivery"], "launch")

        // The next launch gets the same report from MetricKit; the event still appears, saying nothing new.
        let second = makeRecorder()
        second.deliver(diagnostics: [cpuException], metrics: [], isLaunch: true)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].fields["reason"], "none_reported")
        XCTAssertEqual(events[1].fields["newReports"], "0")
    }

    func testALateDeliveryWritesAnEventOnlyWhenItBringsANewReport() {
        let recorder = makeRecorder()
        recorder.deliver(diagnostics: [], metrics: [], isLaunch: true)
        recorder.deliver(diagnostics: [], metrics: [], isLaunch: false)
        XCTAssertEqual(events.count, 1, "an empty late delivery is not an event")

        recorder.deliver(diagnostics: [cpuException], metrics: [], isLaunch: false)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].fields["delivery"], "late")
        XCTAssertEqual(events[1].fields["reason"], "cpu_exception")

        recorder.deliver(diagnostics: [cpuException], metrics: [], isLaunch: false)
        XCTAssertEqual(events.count, 2, "the same report again")
    }
}
#endif
