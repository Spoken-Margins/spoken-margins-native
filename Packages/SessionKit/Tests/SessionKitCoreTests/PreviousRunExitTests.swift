import Foundation
import XCTest
@testable import SessionKit

/// #1682: the 4 stops in #1679 had to be inferred from gaps in the log. These use the shape of
/// `MXDiagnosticPayload.jsonRepresentation()` and `MXMetricPayload.jsonRepresentation()`, trimmed to what is read.
final class PreviousRunExitTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    private let cpuAndHang = """
    {
      "version" : "1.0.0",
      "timeStampBegin" : "2026-10-14 09:00:00",
      "timeStampEnd" : "2026-10-15 09:00:00",
      "cpuExceptionDiagnostics" : [
        {
          "version" : "1.0.0",
          "callStackTree" : { "callStacks" : [ { "threadAttributed" : true } ], "callStackPerThread" : false },
          "diagnosticMetaData" : {
            "bundleIdentifier" : "com.example.listener",
            "deviceType" : "iPhone17,1",
            "osVersion" : "iPhone OS 26.0 (23A000)",
            "totalCPUTime" : "92 sec",
            "totalSampledTime" : "300 sec"
          }
        }
      ],
      "hangDiagnostics" : [
        { "version" : "1.0.0", "diagnosticMetaData" : { "hangDuration" : "4 sec" } },
        { "version" : "1.0.0", "diagnosticMetaData" : { "hangDuration" : "9 sec" } }
      ]
    }
    """

    private let crash = """
    {
      "timeStampBegin" : "2026-10-15 09:00:00",
      "timeStampEnd" : "2026-10-16 09:00:00",
      "crashDiagnostics" : [
        {
          "diagnosticMetaData" : {
            "exceptionType" : 6,
            "exceptionCode" : 0,
            "signal" : 5,
            "terminationReason" : "Namespace SIGNAL, Code 0x5",
            "exceptionReason" : { "composedMessage" : "Title of The Article I Was Reading" }
          }
        }
      ]
    }
    """

    private let exits = """
    {
      "timeStampBegin" : "2026-10-14 00:00:00 +0000",
      "timeStampEnd" : "2026-10-14 23:59:00 +0000",
      "applicationExitMetrics" : {
        "backgroundExitData" : {
          "cumulativeCPUResourceLimitExitCount" : 3,
          "cumulativeMemoryResourceLimitExitCount" : 0,
          "cumulativeAppWatchdogExitCount" : 1,
          "cumulativeNormalAppExitCount" : 9
        },
        "foregroundExitData" : {
          "cumulativeMemoryResourceLimitExitCount" : 0,
          "cumulativeNormalAppExitCount" : 4
        }
      }
    }
    """

    func testCpuExceptionAndHangsAreNamedWithTheirNumbers() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(cpuAndHang)], metricPayloads: [])
        XCTAssertEqual(exit.fields["source"], "metrickit")
        XCTAssertEqual(exit.fields["reason"], "cpu_exception,hang")
        XCTAssertEqual(exit.fields["cpuExceptions"], "1")
        XCTAssertEqual(exit.fields["hangs"], "2")
        XCTAssertEqual(exit.fields["crashes"], "0")
        XCTAssertEqual(exit.fields["cpuTime"], "92 sec")
        XCTAssertEqual(exit.fields["cpuSampledTime"], "300 sec")
        XCTAssertEqual(exit.fields["hangDuration"], "9 sec", "the newest hang")
        XCTAssertEqual(exit.fields["diagnosticsPeriod"], "2026-10-14 09:00:00 to 2026-10-15 09:00:00")
        XCTAssertEqual(exit.newReports, 1)
    }

    func testCrashKeepsTheSystemCodesButNotTheExceptionText() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(crash)], metricPayloads: [])
        XCTAssertEqual(exit.fields["reason"], "crash")
        XCTAssertEqual(exit.fields["crashExceptionType"], "6")
        XCTAssertEqual(exit.fields["crashSignal"], "5")
        XCTAssertEqual(exit.fields["crashTermination"], "Namespace SIGNAL, Code 0x5")
        let everything = exit.fields.keys.joined() + exit.fields.values.joined()
        XCTAssertFalse(everything.contains("Article"), "exception text can quote what the listener was reading")
    }

    func testNothingFromTheReportCanIdentifyTheListenerOrThePhone() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(cpuAndHang), data(crash)], metricPayloads: [data(exits)])
        let everything = exit.fields.keys.joined(separator: " ") + " " + exit.fields.values.joined(separator: " ")
        for leak in ["com.example", "iPhone17", "iPhone OS", "callStack", "Article"] {
            XCTAssertFalse(everything.contains(leak), leak)
        }
    }

    func testFreeTextInASystemFieldReadsOtherInsteadOfPassingThrough() {
        let json = """
        { "crashDiagnostics" : [ { "diagnosticMetaData" : {
            "terminationReason" : "Open \\"My Private Notes.pdf\\" failed at /private/var/mobile/x" } } ] }
        """
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: [])
        XCTAssertEqual(exit.fields["crashTermination"], "other")
        let long = String(repeating: "a", count: 61)
        let tooLong = PreviousRunExit.summarize(
            diagnosticPayloads: [data(#"{ "crashDiagnostics" : [ { "diagnosticMetaData" : { "terminationReason" : "\#(long)" } } ] }"#)],
            metricPayloads: [])
        XCTAssertEqual(tooLong.fields["crashTermination"], "other")
    }

    func testBackgroundExitCountsNameTheReasonAndLeaveOutWhatTheReportOmits() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [], metricPayloads: [data(exits)])
        XCTAssertEqual(exit.fields["reason"], "background_cpu_limit,background_watchdog")
        XCTAssertEqual(exit.fields["bgCpuLimit"], "3")
        XCTAssertEqual(exit.fields["bgMemoryLimit"], "0")
        XCTAssertEqual(exit.fields["fgMemoryLimit"], "0")
        XCTAssertNil(exit.fields["bgMemoryPressure"], "not in the report, so not shown as zero")
        XCTAssertNil(exit.fields["fgWatchdog"])
        XCTAssertNil(exit.fields["crashes"], "no diagnostic report came with it")
        XCTAssertEqual(exit.fields["exitsPeriod"], "2026-10-14 00:00:00 to 2026-10-14 23:59:00")
    }

    func testExitCountsAddUpAcrossReports() {
        let nextDay = exits
            .replacingOccurrences(of: "2026-10-14 00:00:00", with: "2026-10-15 00:00:00")
            .replacingOccurrences(of: "2026-10-14 23:59:00", with: "2026-10-15 23:59:00")
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [], metricPayloads: [data(exits), data(nextDay)])
        XCTAssertEqual(exit.fields["bgCpuLimit"], "6")
        XCTAssertEqual(exit.fields["exitsPeriod"], "2026-10-14 00:00:00 to 2026-10-15 23:59:00")
        XCTAssertEqual(exit.newReports, 2)
    }

    func testNoReportsSaysSoInsteadOfLeavingTheEventOut() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [], metricPayloads: [])
        XCTAssertEqual(exit.fields["reason"], "none_reported")
        XCTAssertEqual(exit.fields["newReports"], "0")
        XCTAssertEqual(exit.newReports, 0)
        XCTAssertEqual(exit.seen, PreviousRunExit.Seen())
    }

    func testAReportIsOnlyCountedOnceAcrossLaunches() {
        let first = PreviousRunExit.summarize(diagnosticPayloads: [data(cpuAndHang)], metricPayloads: [data(exits)])
        XCTAssertEqual(first.seen.diagnosticsThrough, "2026-10-15 09:00:00")
        XCTAssertEqual(first.seen.metricsThrough, "2026-10-14 23:59:00")

        // MetricKit hands the same reports over again the next time the app starts.
        let again = PreviousRunExit.summarize(diagnosticPayloads: [data(cpuAndHang)], metricPayloads: [data(exits)], seen: first.seen)
        XCTAssertEqual(again.newReports, 0)
        XCTAssertEqual(again.fields["reason"], "none_reported")
        XCTAssertEqual(again.seen, first.seen)

        // A newer report next to the old one: only the newer one is counted.
        let later = PreviousRunExit.summarize(diagnosticPayloads: [data(cpuAndHang), data(crash)], metricPayloads: [], seen: first.seen)
        XCTAssertEqual(later.newReports, 1)
        XCTAssertEqual(later.fields["reason"], "crash")
        XCTAssertEqual(later.fields["cpuExceptions"], "0", "the one already reported is not counted again")
        XCTAssertEqual(later.seen.diagnosticsThrough, "2026-10-16 09:00:00")
        XCTAssertEqual(later.seen.metricsThrough, "2026-10-14 23:59:00", "kept")
    }

    func testReportsInAnyOrderAndJunkAreHandled() {
        let exit = PreviousRunExit.summarize(
            diagnosticPayloads: [data(crash), Data("not json".utf8), data(cpuAndHang), data("[1, 2]")],
            metricPayloads: [Data(), data(#"{"cpuMetrics":{}}"#)])
        XCTAssertEqual(exit.fields["reason"], "crash,cpu_exception,hang")
        XCTAssertEqual(exit.newReports, 2, "junk and a report without an app-exit section are not reports")
        XCTAssertEqual(exit.fields["diagnosticsPeriod"], "2026-10-14 09:00:00 to 2026-10-16 09:00:00")
        XCTAssertEqual(exit.seen.diagnosticsThrough, "2026-10-16 09:00:00")
    }
}
