import Foundation
import XCTest
@testable import SessionKit

/// A catch-up run that resumed a re-listen keeps the listener's place (#5238): the run still ends paused at the reply,
/// and the re-listen's place comes back on the next Play or leave unless the listener moved the playhead first.
final class CatchUpPlaceTests: XCTestCase {
    private func anchor(_ id: String, _ ms: Int) -> MarginMomentAnchor { MarginMomentAnchor(marginId: id, mediaTimeMs: ms) }

    /// A note as a catch-up run leaves it once its reply has the floor: owed, and a Margin passed when the place is ahead.
    private func runNote(returnTo: Int, replyAt: Int) throws -> ReviewReturnPlace {
        var sequence = try XCTUnwrap(MarginMomentSequence(
            itemId: "ep", reviewing: [anchor("r", replyAt)], returnToMediaTimeMs: returnTo, resumesAtEnd: false, endsPaused: true))
        var note = try XCTUnwrap(ReviewReturnPlace(sequence: sequence))
        XCTAssertEqual(sequence.progressed(from: replyAt - 200, to: replyAt + 100)?.marginId, "r")
        switch note.standing(whenReviewIs: sequence) {
        case .owed(let kept): note = kept
        case .released: return note // a place behind the reply: `passedAMargin` stays unset
        }
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: replyAt + 100), .reviewDone(returnToMediaTimeMs: nil, resumes: false),
                       "the run still ends paused at the reply (#4785)")
        return note
    }

    /// The issue's row: finished, re-listened to 24:00 (40%), a reply at 05:00.
    func testTheFortyPercentReListenComesBackAfterTheRun() throws {
        let note = try runNote(returnTo: 1_440_000, replyAt: 300_000)
        let held = try XCTUnwrap(CatchUpPlace.hold(note, sourceAtMediaTimeMs: 300_100), "the place stays owed at the run's end")
        XCTAssertEqual(held.heldAtMediaTimeMs, 300_100)
        XCTAssertEqual(CatchUpPlace.settle(held, itemId: "ep", sourceAtMediaTimeMs: 300_100), .giveBack(toMediaTimeMs: 1_440_000))
        XCTAssertEqual(CatchUpPlace.settle(held, itemId: "ep", sourceAtMediaTimeMs: 900_000), .drop, "a scrub to 15:00 keeps 15:00")
    }

    func testRoundTwoNeverGoesBackToTheOldReply() throws {
        // The first run left a new session at the old reply (05:00); the next reply is at 12:00.
        let note = try runNote(returnTo: 300_000, replyAt: 720_000)
        XCTAssertNil(CatchUpPlace.hold(note, sourceAtMediaTimeMs: 720_100))
    }

    func testHoldOnlyAnOwedPlaceAheadOfTheSource() throws {
        let owed = try runNote(returnTo: 1_440_000, replyAt: 300_000)
        XCTAssertNotNil(CatchUpPlace.hold(owed, sourceAtMediaTimeMs: 300_100))
        let unpassed = try XCTUnwrap(ReviewReturnPlace(sequence: XCTUnwrap(MarginMomentSequence(
            itemId: "ep", reviewing: [anchor("r", 300_000)], returnToMediaTimeMs: 1_440_000, resumesAtEnd: false, endsPaused: true))))
        XCTAssertNil(CatchUpPlace.hold(unpassed, sourceAtMediaTimeMs: 300_100), "no Margin had the floor")
        XCTAssertNil(CatchUpPlace.hold(owed, sourceAtMediaTimeMs: 1_439_600), "within half a second is already there")
        XCTAssertNil(CatchUpPlace.hold(owed, sourceAtMediaTimeMs: nil), "an article has no media time (known limit)")
        XCTAssertNil(CatchUpPlace.hold(nil, sourceAtMediaTimeMs: 300_100))
    }

    func testSettleTable() throws {
        let held = try XCTUnwrap(CatchUpPlace.hold(try runNote(returnTo: 1_440_000, replyAt: 300_000), sourceAtMediaTimeMs: 300_000))
        let unheld = try runNote(returnTo: 1_440_000, replyAt: 300_000)
        struct Row { let name: String; let note: ReviewReturnPlace?; let item: String?; let at: Int?; let expected: CatchUpPlace.Outcome }
        let rows = [
            Row(name: "at the held place", note: held, item: "ep", at: 300_000, expected: .giveBack(toMediaTimeMs: 1_440_000)),
            Row(name: "a save's rejoin, 3 s before", note: held, item: "ep", at: 297_000, expected: .giveBack(toMediaTimeMs: 1_440_000)),
            Row(name: "3 s after", note: held, item: "ep", at: 303_000, expected: .giveBack(toMediaTimeMs: 1_440_000)),
            Row(name: "3.1 s away", note: held, item: "ep", at: 303_100, expected: .drop),
            Row(name: "3.1 s before", note: held, item: "ep", at: 296_900, expected: .drop),
            Row(name: "no position", note: held, item: "ep", at: nil, expected: .drop),
            Row(name: "another item", note: held, item: "other", at: 300_000, expected: .nothing),
            Row(name: "no item", note: held, item: nil, at: 300_000, expected: .nothing),
            Row(name: "an ordinary review's note", note: unheld, item: "ep", at: 300_000, expected: .nothing),
            Row(name: "no note", note: nil, item: "ep", at: 300_000, expected: .nothing),
        ]
        for row in rows {
            XCTAssertEqual(CatchUpPlace.settle(row.note, itemId: row.item, sourceAtMediaTimeMs: row.at), row.expected, row.name)
        }
    }
}
