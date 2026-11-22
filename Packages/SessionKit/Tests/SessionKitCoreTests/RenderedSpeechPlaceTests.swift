import XCTest
@testable import SessionKit

/// Where the on-device voice says the listener is (#4310). The Supertonic client answers `currentCharOffset()` with
/// `RenderedSpeechPlace`; `SupertonicSpeechTests.testAfterAStopTheClientStillReportsWhereItsLastSpeechStarted` checks
/// the real client after a stop on the app host.
final class RenderedSpeechPlaceTests: XCTestCase {
    private let text = "First sentence. Second sentence. Third sentence."

    private func place(
        _ source: String? = nil, chunkStart: Int, chunkLength: Int, requestedStart: Int? = nil, duration: TimeInterval
    ) -> RenderedSpeechPlace {
        RenderedSpeechPlace(
            projection: SpeechTextNormalizer.normalizeWithSourceOffsets(source ?? text), chunkStart: chunkStart,
            chunkLength: chunkLength, requestedStart: requestedStart, chunkDuration: duration)
    }

    /// The state `stop()` leaves: no audio loaded, the projection and the last chunk's start kept. The voice still
    /// reports that start, which the engine must not read as the listener's place after a refused start (#4199). The
    /// stand-in `RefusingAtTheEndSpeech(keepsLastOffsetAfterStop:)` reports its stale offset through this case.
    func testAStoppedVoiceStillReportsWhereItsLastChunkStarted() {
        let stopped = place(chunkStart: 16, chunkLength: 0, duration: 0)
        XCTAssertEqual(stopped.sourceOffset(playerTime: 0), 16, "the last chunk's start, not nil")
        XCTAssertEqual(stopped.sourceOffset(playerTime: 12), 16, "a clock with no audio behind it moves nothing")
        XCTAssertEqual(place(chunkStart: 16, chunkLength: 16, duration: 0).sourceOffset(playerTime: 3), 16, "a chunk with no audio yet")
    }

    func testThePlaceMovesThroughTheChunkWithItsAudio() {
        let playing = place(chunkStart: 16, chunkLength: 16, duration: 4)
        XCTAssertEqual(playing.sourceOffset(playerTime: 0), 16)
        XCTAssertEqual(playing.sourceOffset(playerTime: 1), 20, "a quarter of the audio is a quarter of the characters")
        XCTAssertEqual(playing.sourceOffset(playerTime: 4), 32)
        XCTAssertEqual(playing.sourceOffset(playerTime: 40), 32, "never past the chunk's end")
        XCTAssertEqual(playing.sourceOffset(playerTime: -1), 16, "never before its start")
        XCTAssertEqual(playing.sourceOffset(playerTime: .nan), 16, "a clock that is not a number reads as the start")
    }

    func testThePlaceIsNeverBeforeWhereTheListenerAskedToStart() {
        let asked = place(chunkStart: 16, chunkLength: 16, requestedStart: 23, duration: 4)
        XCTAssertEqual(asked.sourceOffset(playerTime: 1), 23, "the audio has not reached the place yet")
        XCTAssertEqual(asked.sourceOffset(playerTime: 3), 28, "and moves on from it once it has")
        XCTAssertEqual(place(chunkStart: 16, chunkLength: 0, requestedStart: 23, duration: 0).sourceOffset(playerTime: 0), 23)
    }

    func testSpokenCharactersMapBackToTheSourceText() throws {
        // Whitespace the voice collapses shifts every later spoken character against the source.
        let source = "First     sentence.\n\n\nSecond sentence."
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        let spokenRange = try XCTUnwrap(projection.text.range(of: "Second"))
        let spoken = projection.text.distance(from: projection.text.startIndex, to: spokenRange.lowerBound)
        let sourceRange = try XCTUnwrap(source.range(of: "Second"))
        let inSource = source.distance(from: source.startIndex, to: sourceRange.lowerBound)
        XCTAssertLessThan(spoken, inSource, "precondition: the spoken text is shorter than the source")
        XCTAssertEqual(place(source, chunkStart: spoken, chunkLength: 0, duration: 0).sourceOffset(playerTime: 0), inSource)
    }
}
