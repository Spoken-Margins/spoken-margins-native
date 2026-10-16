import XCTest
@testable import SessionKit

/// #538: Supertonic went silent when the app was in the background, because the chunk seam needed the app to run.
/// The decision to put the next chunk on the player ahead of time, and the counts an export shows.
final class BackgroundChunkSeamTests: XCTestCase {
    private func facts(
        active: Bool = false,
        plays: Bool = true,
        exists: Bool = true,
        rendered: Bool = true,
        standIn: Bool = false,
        queued: Bool = false
    ) -> BackgroundChunkSeam.Facts {
        BackgroundChunkSeam.Facts(
            appIsActive: active,
            intendsToPlay: plays,
            nextChunkExists: exists,
            nextChunkIsRendered: rendered,
            nextChunkIsStandIn: standIn,
            alreadyQueued: queued
        )
    }

    /// Every fact flipped on its own from the one case that queues, so no condition can drop out unnoticed.
    func testTheNextChunkIsQueuedOnlyWhenEveryConditionHolds() {
        XCTAssertTrue(BackgroundChunkSeam.shouldQueueAhead(facts()))
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(active: true)), "in front, the seam is unchanged")
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(plays: false)), "paused or stopped")
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(exists: false)), "the last chunk of the text")
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(rendered: false)), "nothing to queue yet")
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(standIn: true)), "another voice needs its cue")
        XCTAssertFalse(BackgroundChunkSeam.shouldQueueAhead(facts(queued: true)), "one chunk ahead at a time")
    }

    func testMissedSeamsNameTheirCause() {
        XCTAssertEqual(
            BackgroundChunkSeam.missedOutcome(nextChunkIsRendered: false, nextChunkIsStandIn: false), .nextNotRendered
        )
        XCTAssertEqual(
            BackgroundChunkSeam.missedOutcome(nextChunkIsRendered: true, nextChunkIsStandIn: false), .renderedNotQueued
        )
        XCTAssertEqual(
            BackgroundChunkSeam.missedOutcome(nextChunkIsRendered: true, nextChunkIsStandIn: true), .standInVoice
        )
        // A stand-in that is still rendering is a stand-in first: its cue is what needs the app.
        XCTAssertEqual(
            BackgroundChunkSeam.missedOutcome(nextChunkIsRendered: false, nextChunkIsStandIn: true), .standInVoice
        )
    }

    func testTheLogCountsSeamsInAFixedOrderAndSaysWhenAnOutcomeIsNew() {
        var log = BackgroundSeamLog()
        XCTAssertNil(log.summary)
        XCTAssertEqual(log.total, 0)

        XCTAssertTrue(log.record(.nextNotRendered))
        XCTAssertTrue(log.record(.queuedAhead))
        XCTAssertFalse(log.record(.queuedAhead))
        XCTAssertFalse(log.record(.queuedAhead))
        XCTAssertFalse(log.record(.nextNotRendered))

        XCTAssertEqual(log.count(.queuedAhead), 3)
        XCTAssertEqual(log.count(.nextNotRendered), 2)
        XCTAssertEqual(log.count(.standInVoice), 0)
        XCTAssertEqual(log.total, 5)
        XCTAssertEqual(log.summary, "queued_ahead 3, next_not_rendered 2")
    }

    // #1673: only a seam with nothing rendered to play hands over to the iOS voice. Every other miss has its audio
    // in hand (or a stand-in voice that needs the app anyway) and carries on through the app.
    func testOnlyANextChunkThatIsNotRenderedHandsOverToTheIOSVoice() {
        for outcome in BackgroundChunkSeam.Outcome.allCases {
            XCTAssertEqual(
                BackgroundChunkSeam.handsOverToSystemVoice(outcome), outcome == .nextNotRendered, outcome.rawValue
            )
        }
    }
}
