import Foundation
import SessionKit
import XCTest

/// The player's on-device voice line and the stored generation state (#1013). The raw values are
/// stored as strings and written to `diagnostics["onDeviceSpeechGeneration"]`, so they must not change.
final class RenderedSpeechGenerationTests: XCTestCase {
    func testStateRawValuesStayStable() {
        XCTAssertEqual(RenderedSpeechGenerationState.inactive.rawValue, "inactive")
        XCTAssertEqual(RenderedSpeechGenerationState.rendering.rawValue, "rendering")
        XCTAssertEqual(RenderedSpeechGenerationState.ready.rawValue, "ready")
        XCTAssertEqual(RenderedSpeechGenerationState.stopped.rawValue, "stopped")
        XCTAssertEqual(RenderedSpeechGenerationState(rawValue: "rendering"), .rendering)
    }

    func testPercentIsZeroWithoutChunksRoundsAndClamps() {
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: 5, totalChunks: 0).percent, 0)
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: 1, totalChunks: 3).percent, 33)
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: 2, totalChunks: 3).percent, 67)
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: 1, totalChunks: 8).percent, 13, "12.5 rounds up")
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: 9, totalChunks: 4).percent, 100)
        XCTAssertEqual(RenderedSpeechGenerationProgress(completedChunks: -3, totalChunks: 4).percent, 0)
    }

    /// #1681 audit: a chain resting on purpose read as a stalled render, "Still preparing" and a delay in diagnostics.
    func testOnlyARenderThatOwesProgressIsWatchedForDelay() {
        XCTAssertTrue(RenderedSpeechGenerationProgress(completedChunks: 3, totalChunks: 10).watchesForDelay)
        XCTAssertFalse(RenderedSpeechGenerationProgress(completedChunks: 3, totalChunks: 10, isRestingAhead: true).watchesForDelay)
        XCTAssertFalse(RenderedSpeechGenerationProgress(completedChunks: 10, totalChunks: 10).watchesForDelay)
        XCTAssertFalse(RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0).watchesForDelay)
        XCTAssertNotEqual(RenderedSpeechGenerationProgress(completedChunks: 3, totalChunks: 10, isRestingAhead: true),
                          RenderedSpeechGenerationProgress(completedChunks: 3, totalChunks: 10),
                          "waking from a rest is new progress, so the app's watch starts again")
    }

    func testListenerSentencesForEachState() {
        func line(_ state: RenderedSpeechGenerationState, _ done: Int, _ total: Int, delayed: Bool = false) -> String {
            state.listenerDescription(
                progress: RenderedSpeechGenerationProgress(completedChunks: done, totalChunks: total),
                isDelayed: delayed, stopReason: nil, fallbackReason: nil)
        }
        XCTAssertEqual(line(.rendering, 0, 0), "Preparing the full Supertonic audio on this iPhone")
        XCTAssertEqual(line(.rendering, 0, 0, delayed: true), "Preparing the full Supertonic audio on this iPhone")
        XCTAssertEqual(line(.rendering, 1, 4), "Generating full audio \u{00B7} 25% (1 of 4 parts)")
        XCTAssertEqual(line(.rendering, 1, 4, delayed: true), "Still preparing part 2 of 4 \u{00B7} 25% complete")
        XCTAssertEqual(line(.rendering, 4, 4, delayed: true), "Still preparing part 4 of 4 \u{00B7} 100% complete",
                       "The part number never passes the total")
        XCTAssertEqual(line(.ready, 4, 4), "Prepared audio is ready for playback")
        XCTAssertEqual(line(.inactive, 0, 0), "On-device voice generation is inactive")
    }

    func testStoppedLineIsTheStopReasonExplanation() {
        for (reason, fallback) in [(nil, nil), ("prepared_audio_assembly_failed: disk", nil), (nil, SpeechFallbackReason.deviceTooWarm)] as [(String?, SpeechFallbackReason?)] {
            XCTAssertEqual(
                RenderedSpeechGenerationState.stopped.listenerDescription(
                    progress: RenderedSpeechGenerationProgress(completedChunks: 2, totalChunks: 4),
                    isDelayed: true, stopReason: reason, fallbackReason: fallback),
                SpeechGenerationStopReason.listenerExplanation(stopReason: reason, fallbackReason: fallback))
        }
    }
}
