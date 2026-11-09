import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #3816: the basic Diagnostics export says what the last Make available offline run cost, with detailed
/// recording off. The real pass is in `LibraryAudioPreparationTests`; the rules for the numbers are in
/// SessionKit's `AudioPreparationRunSummaryTests`. This is the wiring in between.
@MainActor
final class AudioPreparationRunDiagnosticsTests: XCTestCase {
    private let key = AudioPreparationRunSummary.diagnosticsKey

    func testAChunkLeavesTheLineAndRefreshDiagnosticsKeepsIt() {
        let diagnostics = RuntimeDiagnostics()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        diagnostics.preparationChunkCommitted(renderMs: 4_000, thermalAtStart: .nominal, thermalAtEnd: .fair, at: start)
        let expected = "chunks=1;renderMsMedian=4000;renderMsP90=4000;heatPauses=0;peakThermal=fair;wallClockS=4"
        XCTAssertEqual(diagnostics.values[key], expected)
        diagnostics.values = [:] // Refresh Diagnostics and resetAndSeed() assign a whole new dictionary
        XCTAssertEqual(diagnostics.values[key], expected)
    }

    func testTheNextRunAfterAQuietSpellReplacesTheLastOne() {
        let diagnostics = RuntimeDiagnostics()
        let first = Date(timeIntervalSinceReferenceDate: 1_000)
        diagnostics.preparationChunkCommitted(renderMs: 9_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: first)
        XCTAssertNotNil(diagnostics.values[key])
        diagnostics.preparationChunkCommitted(
            renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal,
            at: first + AudioPreparationRunTracker.idleGap + 60)
        XCTAssertEqual(diagnostics.values[key], "chunks=1;renderMsMedian=1000;renderMsP90=1000;heatPauses=0;peakThermal=nominal;wallClockS=1")
    }

    func testAChunkAfterTheQueueDrainedStartsANewRunEvenWithinTheQuietGap() {
        let diagnostics = RuntimeDiagnostics()
        let first = Date(timeIntervalSinceReferenceDate: 1_000)
        diagnostics.preparationChunkCommitted(renderMs: 9_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: first)
        diagnostics.preparationQueueDrained()
        diagnostics.preparationChunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: first + 15 * 60)
        XCTAssertEqual(diagnostics.values[key], "chunks=1;renderMsMedian=1000;renderMsP90=1000;heatPauses=0;peakThermal=nominal;wallClockS=1")
    }

    func testAHeatPauseAtTheGateIsCountedAndAnyOtherGateIsNot() throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: FileManager.default.temporaryDirectory
                                    .appending(path: "run-diagnostics-\(UUID().uuidString).sqlite"))
        for other in [PreparationChunkDecision.render, .waitForLowPowerMode, .dropListenedItem] {
            model.notePreparationHeatPause(other, thermal: .nominal)
        }
        XCTAssertNil(model.runtimeDiagnostics.values[key], "no heat pause, no line")
        model.notePreparationHeatPause(.pauseForHeat, thermal: .serious)
        let line = try XCTUnwrap(model.runtimeDiagnostics.values[key])
        XCTAssertTrue(line.hasPrefix("chunks=0;"), line)
        XCTAssertTrue(line.contains("heatPauses=1;peakThermal=serious;"), line)
    }

    /// A loop that ends while another keeps the queue (the foreground loop finding the background task holding
    /// the turn) must not cut the run in two: nothing ends a run but a quiet spell (audit on c64d9e6).
    func testALoopEndingMidRunDoesNotSplitTheRun() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: FileManager.default.temporaryDirectory
                                    .appending(path: "run-diagnostics-\(UUID().uuidString).sqlite"))
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            pause: { _ in }
        )
        model.runtimeDiagnostics.preparationChunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal)
        await model.runForegroundPreparationLoop { false } // nothing to do, and nothing to wait for
        model.runtimeDiagnostics.preparationChunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal)
        let line = try XCTUnwrap(model.runtimeDiagnostics.values[key])
        XCTAssertTrue(line.hasPrefix("chunks=2;"), line)
    }
}
