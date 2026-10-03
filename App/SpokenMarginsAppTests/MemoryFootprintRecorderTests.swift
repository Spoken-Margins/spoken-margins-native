import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #122: the app was killed for memory twice and nothing recorded how much it used.
@MainActor
final class MemoryFootprintRecorderTests: XCTestCase {
    private var fileURL: URL!
    private var clock = Date(timeIntervalSince1970: 1_790_000_000) // 09-21 14:13:20Z
    private var footprintMB: UInt64 = 200

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-footprint-\(UUID().uuidString)/memory-footprint.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeRecorder(diagnostics: RuntimeDiagnostics) -> MemoryFootprintRecorder {
        MemoryFootprintRecorder(
            diagnostics: PinnedDiagnostics(diagnostics: diagnostics),
            fileURL: fileURL,
            read: { [unowned self] in .init(footprintBytes: self.footprintMB * 1_048_576, availableBytes: nil) },
            now: { [unowned self] in self.clock }
        )
    }

    private func snapshot(_ itemId: String?, _ status: PlaybackStatus) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.itemId = itemId
        snapshot.status = status
        return snapshot
    }

    func testPodcastToArticleSequenceIsSampledAndSurvivesARelaunch() throws {
        let diagnostics = RuntimeDiagnostics()
        let recorder = makeRecorder(diagnostics: diagnostics)
        recorder.record(.launch, mediaType: nil)

        recorder.observe(snapshot("podcast-1", .playing), mediaType: { "podcast" })
        clock += 30
        footprintMB = 260
        recorder.observe(snapshot("podcast-1", .playing), mediaType: { "podcast" }) // not due yet
        clock += 31
        recorder.observe(snapshot("podcast-1", .playing), mediaType: { "podcast" }) // a minute after the start
        recorder.observe(snapshot("podcast-1", .paused), mediaType: { "podcast" })
        clock += 5
        footprintMB = 900
        recorder.observe(snapshot("article-1", .starting), mediaType: { "text" })

        XCTAssertEqual(diagnostics.values["memoryFootprint"], [
            "09-21 14:13:20Z launch none 200MB",
            "09-21 14:13:20Z item_start podcast 200MB",
            "09-21 14:14:21Z playback podcast 260MB",
            "09-21 14:14:26Z item_switch text 900MB",
        ].joined(separator: " | "))

        // iOS ends the app. The next launch still has the samples taken before the kill.
        let relaunchDiagnostics = RuntimeDiagnostics()
        let relaunched = makeRecorder(diagnostics: relaunchDiagnostics)
        clock += 120
        footprintMB = 150
        relaunched.record(.launch, mediaType: nil)
        relaunched.observe(snapshot("article-1", .playing), mediaType: { "text" })
        let line = try XCTUnwrap(relaunchDiagnostics.values["memoryFootprint"])
        XCTAssertTrue(line.hasPrefix("09-21 14:13:20Z launch none 200MB"), line)
        XCTAssertTrue(line.hasSuffix("item_switch text 900MB | 09-21 14:16:26Z launch none 150MB | 09-21 14:16:26Z item_start text 150MB"), line)
    }

    func testAMemoryWarningIsSampledEvenWhenPaused() {
        let diagnostics = RuntimeDiagnostics()
        let recorder = makeRecorder(diagnostics: diagnostics)
        recorder.record(.memoryWarning, mediaType: "text")
        XCTAssertEqual(diagnostics.values["memoryFootprint"], "09-21 14:13:20Z memory_warning text 200MB")
        XCTAssertNotNil(MemoryFootprintRecorder.readCurrent()?.footprintBytes, "the real reader works on this device")
    }

    func testRefreshDiagnosticsDoesNotDropTheMemoryLines() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let pinned = PinnedDiagnostics(diagnostics: model.runtimeDiagnostics)
        let recorder = MemoryFootprintRecorder(
            diagnostics: pinned, fileURL: nil,
            read: { .init(footprintBytes: 300 * 1_048_576, availableBytes: nil) },
            now: { [unowned self] in self.clock }
        )
        recorder.record(.launch, mediaType: nil)
        pinned.set("memoryExits", "foreground 1 · background 0 · background system pressure 0")

        model.refreshDiagnostics() // the Settings button: replaces the whole dictionary
        let restored = expectation(description: "pinned lines put back on the next main-queue turn")
        DispatchQueue.main.async { DispatchQueue.main.async { restored.fulfill() } }
        wait(for: [restored], timeout: 2)

        XCTAssertEqual(model.diagnostics["memoryFootprint"], "09-21 14:13:20Z launch none 300MB")
        XCTAssertEqual(model.diagnostics["memoryExits"], "foreground 1 · background 0 · background system pressure 0")
    }

    func testMemoryExitsLineComesFromTheNewestReportWithExitData() {
        let older = Data(#"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeMemoryResourceLimitExitCount":2}}}"#.utf8)
        let newer = Data(#"{"applicationExitMetrics":{"foregroundExitData":{"cumulativeMemoryResourceLimitExitCount":0},"backgroundExitData":{"cumulativeMemoryResourceLimitExitCount":1,"cumulativeMemoryPressureExitCount":0}}}"#.utf8)
        let withoutExits = Data(#"{"cpuMetrics":{}}"#.utf8)
        XCTAssertEqual(MemoryExitMetricsSubscriber.diagnosticsLine(forPayloadJSON: [older, newer, withoutExits]),
                       "foreground 0 · background 1 · background system pressure 0")
        XCTAssertNil(MemoryExitMetricsSubscriber.diagnosticsLine(forPayloadJSON: []))

        let dated = { (end: String, count: Int) in
            Data(#"{"timeStampBegin":"\#(end) 00:00:00 +0000","timeStampEnd":"\#(end) 23:59:00 +0000","applicationExitMetrics":{"foregroundExitData":{"cumulativeMemoryResourceLimitExitCount":\#(count)}}}"#.utf8)
        }
        XCTAssertEqual(MemoryExitMetricsSubscriber.diagnosticsLine(forPayloadJSON: [dated("2026-09-30", 3), dated("2026-09-29", 1)]),
                       "foreground 3 · background not reported · background system pressure not reported · 2026-09-30 to 2026-09-30",
                       "the latest period wins whatever the order")
    }
}
