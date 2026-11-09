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

    func testTheNextRunReplacesTheEndedOne() {
        let diagnostics = RuntimeDiagnostics()
        let first = Date(timeIntervalSinceReferenceDate: 1_000)
        diagnostics.preparationChunkCommitted(renderMs: 9_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: first)
        diagnostics.preparationRunEnded()
        XCTAssertNotNil(diagnostics.values[key], "an ended run's line stays")
        diagnostics.preparationChunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: first + 600)
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

    func testTheLoopEndingEndsTheRunSoTheNextOneStartsFresh() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: FileManager.default.temporaryDirectory
                                    .appending(path: "run-diagnostics-\(UUID().uuidString).sqlite"))
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            pause: { _ in }
        )
        model.runtimeDiagnostics.preparationHeatPaused(thermal: .critical)
        await model.runForegroundPreparationLoop { false } // nothing to do, and nothing to wait for
        model.runtimeDiagnostics.preparationHeatPaused(thermal: .nominal)
        let line = try XCTUnwrap(model.runtimeDiagnostics.values[key])
        XCTAssertTrue(line.contains("heatPauses=1;peakThermal=nominal;"), "the second run didn't inherit the first's heat: \(line)")
    }
}
