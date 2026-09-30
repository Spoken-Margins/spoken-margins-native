import XCTest
@testable import SessionKit

/// #305: text items showed only "N%". These pin the time-left estimate the player and Library use.
final class ListeningTimeEstimatorTests: XCTestCase {
    // 16,800 characters at the typical 14 a second is 20 minutes at 1×.
    private let articleCharacters = 16_800

    func testTypicalRateAtNormalSpeed() throws {
        let estimate = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: articleCharacters, charactersHeard: 4_200, playbackSpeed: 1
        ))
        XCTAssertEqual(estimate.basis, .typical)
        XCTAssertEqual(estimate.totalSeconds, 1_200, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingSeconds, 900, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingText, "about 15 min left")
        XCTAssertEqual(estimate.totalText, "about 20 min")
        XCTAssertEqual(estimate.remainingSpokenText, "about 15 minutes left")
    }

    func testDoubleSpeedHalvesTheTime() throws {
        let estimate = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: articleCharacters, charactersHeard: 4_200, playbackSpeed: 2
        ))
        XCTAssertEqual(estimate.totalSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingSeconds, 450, accuracy: 0.001)
        XCTAssertEqual(estimate.remainingText, "about 8 min left")
        XCTAssertEqual(estimate.totalText, "about 10 min")
    }

    func testMeasuredRateWinsOverTypical() throws {
        // A slower voice measured at 12 characters a second at 1×.
        let atNormal = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 7_200, charactersHeard: 0, playbackSpeed: 1, measuredCharactersPerSecond: 12
        ))
        XCTAssertEqual(atNormal.basis, .measured)
        XCTAssertEqual(atNormal.remainingSeconds, 600, accuracy: 0.001)

        let atDouble = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 7_200, charactersHeard: 0, playbackSpeed: 2, measuredCharactersPerSecond: 12
        ))
        XCTAssertEqual(atDouble.remainingSeconds, 300, accuracy: 0.001)
    }

    func testImplausibleMeasurementFallsBackToTypical() throws {
        for bogus in [0, 3, 90, Double.nan, .infinity] {
            let estimate = try XCTUnwrap(ListeningTimeEstimator.estimate(
                totalCharacters: 1_400, charactersHeard: 0, playbackSpeed: 1, measuredCharactersPerSecond: bogus
            ))
            XCTAssertEqual(estimate.basis, .typical, "\(bogus)")
            XCTAssertEqual(estimate.remainingSeconds, 100, accuracy: 0.001, "\(bogus)")
        }
    }

    func testPositionAndSpeedAreClamped() throws {
        let past = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 1_400, charactersHeard: 5_000, playbackSpeed: 1
        ))
        XCTAssertEqual(past.remainingSeconds, 0)
        XCTAssertEqual(past.remainingText, "under 1 min left")
        XCTAssertEqual(past.remainingSpokenText, "less than a minute left")

        let before = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 1_400, charactersHeard: -10, playbackSpeed: 0
        ))
        XCTAssertEqual(before.remainingSeconds, 100, accuracy: 0.001)

        XCTAssertNil(ListeningTimeEstimator.estimate(totalCharacters: 0, charactersHeard: 0, playbackSpeed: 1))
    }

    func testLongItemsReadInHoursAndMinutes() throws {
        // 65 minutes at 1×.
        let estimate = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 54_600, charactersHeard: 0, playbackSpeed: 1
        ))
        XCTAssertEqual(estimate.remainingText, "about 1 h 5 min left")
        XCTAssertEqual(estimate.totalText, "about 1 h 5 min")
        XCTAssertEqual(estimate.remainingSpokenText, "about 1 hour 5 minutes left")

        let exactHour = try XCTUnwrap(ListeningTimeEstimator.estimate(
            totalCharacters: 50_400, charactersHeard: 0, playbackSpeed: 1
        ))
        XCTAssertEqual(exactHour.totalText, "about 1 h")
        XCTAssertEqual(exactHour.remainingSpokenText, "about 1 hour left")
    }

    func testMeasuresRenderedChunksAtNormalSpeed() throws {
        // Two 15 s chunks of 210 characters each: 14 a second.
        let chunks = [chunk(0, from: 0, to: 210, ms: 15_000), chunk(1, from: 210, to: 420, ms: 15_000)]
        let rate = try XCTUnwrap(ListeningTimeEstimator.measuredCharactersPerSecond(chunks: chunks))
        XCTAssertEqual(rate, 14, accuracy: 0.001)

        // The same audio rendered at speed 1.5 took a third less time, so its 1× rate is the same.
        let fastChunks = [chunk(0, from: 0, to: 210, ms: 10_000), chunk(1, from: 210, to: 420, ms: 10_000)]
        let fastRate = try XCTUnwrap(ListeningTimeEstimator.measuredCharactersPerSecond(chunks: fastChunks, renderSpeed: 1.5))
        XCTAssertEqual(fastRate, 14, accuracy: 0.001)
    }

    func testMeasurementConvertsUTF8BytesToCharacters() throws {
        // 420 bytes that are 350 characters (curly quotes and dashes) over 25 s: 14 characters a second.
        let chunks = [chunk(0, from: 0, to: 420, ms: 25_000)]
        let rate = try XCTUnwrap(ListeningTimeEstimator.measuredCharactersPerSecond(
            chunks: chunks, utf8BytesPerCharacter: 420.0 / 350.0
        ))
        XCTAssertEqual(rate, 14, accuracy: 0.001)
    }

    func testMeasurementSkipsBabbleAndNeedsEnoughAudio() throws {
        XCTAssertNil(ListeningTimeEstimator.measuredCharactersPerSecond(chunks: []))
        // 10 s of good audio is too little to trust.
        XCTAssertNil(ListeningTimeEstimator.measuredCharactersPerSecond(chunks: [chunk(0, from: 0, to: 140, ms: 10_000)]))

        // A babbled chunk (5 characters a second) is left out rather than dragging the rate down.
        let chunks = [
            chunk(0, from: 0, to: 280, ms: 20_000),
            chunk(1, from: 280, to: 380, ms: 20_000),
            chunk(2, from: 380, to: 660, ms: 20_000)
        ]
        let rate = try XCTUnwrap(ListeningTimeEstimator.measuredCharactersPerSecond(chunks: chunks))
        XCTAssertEqual(rate, 14, accuracy: 0.001)
    }

    private func chunk(_ index: Int, from start: Int, to end: Int, ms: Int) -> PreparedAudioChunk {
        PreparedAudioChunk(
            id: "c\(index)",
            index: index,
            sourceRange: SourceLocator(documentId: "doc", segmentId: "s\(index)", utf8Start: start, utf8End: end),
            relativePath: "c\(index).m4a",
            byteCount: 1,
            checksumSHA256: "c\(index)",
            durationMs: ms
        )
    }
}
