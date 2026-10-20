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

    /// #2184: a watchdog kill was reported as `other` because its reason is a long description with an app name in it.
    func testATerminationReasonKeepsTheSystemsCodeAndNothingElseOfIt() {
        func termination(_ reason: String) -> String? {
            let escaped = reason.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let json = #"{ "crashDiagnostics" : [ { "diagnosticMetaData" : { "terminationReason" : "\#(escaped)" } } ] }"#
            return PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: []).fields["crashTermination"]
        }
        let table: [(String, String)] = [
            ("Namespace SIGNAL, Code 0x5", "Namespace SIGNAL, Code 0x5"),
            ("Namespace FRONTBOARD, Code 0x8badf00d", "Namespace FRONTBOARD, Code 0x8badf00d"),
            ("<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:[application<com.example.Margins>:221] failed to terminate gracefully>",
             "domain:10, code:0x8BADF00D"),
            ("Namespace RUNNINGBOARD, Code 0xdead10cc; opening /private/var/mobile/Notes.pdf", "Namespace RUNNINGBOARD, Code 0xdead10cc"),
            ("(code:12 /private/x)", "code:12"),
            ("(Namespace Smith /private/x)", "other"),
            ("(Domain 2 notes /private/x)", "other"),
            ("(my code 1234 /private/x)", "other"),
            ("Open \"My Private Notes.pdf\" failed at /private/var/mobile/x", "other"),
            ("code:0x" + String(repeating: "f", count: 17) + " /private/x", "other"),
            ("barcode:12 of /private/x", "other"),
            ("/private/x code:abc", "other"),
            ("<>", "other"),
        ]
        for (reason, expected) in table {
            XCTAssertEqual(termination(reason), expected, reason)
        }
        let leaked = termination("<RBSTerminateContext| domain:10 code:0x8BADF00D explanation:[application<com.example.Margins>:221]>") ?? ""
        XCTAssertFalse(leaked.contains("com.example"))
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

    // MARK: - Call stacks (#2099)

    /// A hang report in MetricKit's `callStackTree` shape: the thread the report is attributed to runs
    /// dyld > app > UIKit > app > app > libsystem, with a lighter side branch; a busier but unattributed
    /// thread carries a different app frame.
    private let hangWithStacks = """
    {
      "timeStampBegin" : "2026-10-19 09:00:00",
      "timeStampEnd" : "2026-10-19 10:00:00",
      "hangDiagnostics" : [
        {
          "callStackTree" : {
            "callStackPerThread" : true,
            "callStacks" : [
              {
                "threadAttributed" : false,
                "callStackRootFrames" : [
                  { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "AAAA0000-0000-0000-0000-000000000001",
                    "offsetIntoBinaryTextSegment" : 99999, "sampleCount" : 500, "subFrames" : [] }
                ]
              },
              {
                "threadAttributed" : true,
                "callStackRootFrames" : [
                  { "binaryName" : "dyld", "binaryUUID" : "DDDD", "offsetIntoBinaryTextSegment" : 1, "sampleCount" : 100,
                    "subFrames" : [
                      { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "AAAA0000-0000-0000-0000-000000000001",
                        "offsetIntoBinaryTextSegment" : 100, "sampleCount" : 100,
                        "subFrames" : [
                          { "binaryName" : "UIKitCore", "binaryUUID" : "UUUU", "offsetIntoBinaryTextSegment" : 7, "sampleCount" : 90,
                            "subFrames" : [
                              { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "AAAA0000-0000-0000-0000-000000000001",
                                "offsetIntoBinaryTextSegment" : 2000, "sampleCount" : 90,
                                "subFrames" : [
                                  { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "AAAA0000-0000-0000-0000-000000000001",
                                    "offsetIntoBinaryTextSegment" : 3000, "sampleCount" : 80,
                                    "subFrames" : [
                                      { "binaryName" : "libsystem_kernel.dylib", "binaryUUID" : "KKKK",
                                        "offsetIntoBinaryTextSegment" : 5, "sampleCount" : 80, "subFrames" : [] }
                                    ] },
                                  { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "AAAA0000-0000-0000-0000-000000000001",
                                    "offsetIntoBinaryTextSegment" : 4000, "sampleCount" : 10, "subFrames" : [] }
                                ] }
                            ] }
                        ] }
                    ] }
                ]
              }
            ]
          },
          "diagnosticMetaData" : { "hangDuration" : "26 sec" }
        }
      ]
    }
    """

    func testAHangKeepsTheAppsFramesOfTheHeaviestPathInnermostFirst() {
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(hangWithStacks)], metricPayloads: [],
                                             appBinaryNames: ["SpokenMarginsApp"])
        XCTAssertEqual(exit.fields["hangFrames"], "0xbb8,0x7d0,0x64", "3000, 2000 and 100, from the busiest path of the attributed thread")
        XCTAssertEqual(exit.fields["hangFramesBinary"], "AAAA0000-0000-0000-0000-000000000001")
        XCTAssertEqual(exit.fields["hangDuration"], "26 sec")
        XCTAssertNil(exit.fields["cpuFrames"])
        let everything = exit.fields.keys.joined(separator: " ") + " " + exit.fields.values.joined(separator: " ")
        for leak in ["callStack", "UIKitCore", "libsystem", "dyld", "KKKK"] {
            XCTAssertFalse(everything.contains(leak), "other binaries and the stack's own keys stay out: \(leak)")
        }
    }

    func testFramesAreCappedAtEightAndOnlyTheAppsOwnBinaryCounts() {
        var frames = #"{ "binaryName" : "SpokenMarginsApp", "binaryUUID" : "B1", "offsetIntoBinaryTextSegment" : 1, "sampleCount" : 1, "subFrames" : [] }"#
        for offset in 2...12 {
            frames = #"{ "binaryName" : "SpokenMarginsApp", "binaryUUID" : "B1", "offsetIntoBinaryTextSegment" : \#(offset), "sampleCount" : 1, "subFrames" : [\#(frames)] }"#
        }
        let json = #"{ "cpuExceptionDiagnostics" : [ { "callStackTree" : { "callStacks" : [ { "threadAttributed" : true, "callStackRootFrames" : [\#(frames)] } ] } } ] }"#
        let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: [], appBinaryNames: ["SpokenMarginsApp"])
        // Root is offset 12, the innermost 1: the eight innermost are 1 to 8.
        XCTAssertEqual(exit.fields["cpuFrames"], "0x1,0x2,0x3,0x4,0x5,0x6,0x7,0x8")
        let other = PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: [], appBinaryNames: ["NotThisApp"])
        XCTAssertNil(other.fields["cpuFrames"])
        let unnamed = PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: [])
        XCTAssertNil(unnamed.fields["cpuFrames"], "no binary name given, no frames kept")
    }

    func testAStackWithoutTheAppsFramesOrWithJunkOffsetsAddsNothing() {
        let noApp = #"{ "hangDiagnostics" : [ { "callStackTree" : { "callStacks" : [ { "threadAttributed" : true, "callStackRootFrames" : [ { "binaryName" : "UIKitCore", "binaryUUID" : "U", "offsetIntoBinaryTextSegment" : 1, "sampleCount" : 1 } ] } ] } } ] }"#
        let junk = #"{ "hangDiagnostics" : [ { "callStackTree" : { "callStacks" : [ { "callStackRootFrames" : [ { "binaryName" : "SpokenMarginsApp", "binaryUUID" : "U", "offsetIntoBinaryTextSegment" : "x", "sampleCount" : 1 } ] } ] } } ] }"#
        let empty = #"{ "hangDiagnostics" : [ { "callStackTree" : { "callStacks" : [] } }, { "diagnosticMetaData" : { "hangDuration" : "1 sec" } } ] }"#
        for json in [noApp, junk, empty] {
            let exit = PreviousRunExit.summarize(diagnosticPayloads: [data(json)], metricPayloads: [], appBinaryNames: ["SpokenMarginsApp"])
            XCTAssertNil(exit.fields["hangFrames"])
            XCTAssertNil(exit.fields["hangFramesBinary"])
        }
    }
}
