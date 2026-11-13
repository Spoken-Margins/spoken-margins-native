import Foundation
import XCTest
@testable import SessionKit

/// #4183: an item the listener finished and then added again reads as a fresh add. `ItemFinishedRule.continuationSessions`
/// is the one rule that says which old sessions still decide the Library row, Continue and the item screen. One test
/// per row of the Design comment's table, plus the neighbours: the same listening at different times, a session with
/// no times, an item never added again, a re-add that stamps nothing, and two re-adds.
final class ContinuationSessionsTests: XCTestCase {
    private let addedAgain = Date(timeIntervalSince1970: 2_000_000)
    private var before: Date { addedAgain.addingTimeInterval(-86_400) }
    private var after: Date { addedAgain.addingTimeInterval(60) }

    private func item(addedAgainAt: Date?) -> Item {
        var item = Item(id: "essay", title: "Essay", mediaType: "article", text: "Some text.", externalReference: nil, status: "ready")
        item.addedAgainAt = addedAgainAt
        return item
    }

    private func session(
        _ id: String, percent: Int, status: String = "active", phase: SessionPhase = .itemPlayback,
        createdAt: Date? = nil, updatedAt: Date? = nil, completedAt: Date? = nil
    ) -> Session {
        Session(id: id, itemId: "essay", createdAt: createdAt, updatedAt: updatedAt, completedAt: completedAt,
                status: status, phase: phase, currentTargetType: .itemTextTTS, currentTargetId: "essay",
                position: Position(charOffset: percent), completionPercent: percent, playbackRate: 1)
    }

    private func ids(_ sessions: [Session]) -> [String] { sessions.map(\.id) }

    private func kept(_ sessions: [Session], addedAgainAt: Date? = nil) -> [String] {
        let date = addedAgainAt ?? addedAgain
        return ids(ItemFinishedRule.continuationSessions(item(addedAgainAt: date), sessions: sessions))
    }

    // MARK: The table, one row each

    func testASessionFinishedBeforeTheReAddNoLongerCounts() {
        let finished = session("done", percent: 100, status: "finished", phase: .finished,
                               createdAt: before, updatedAt: before, completedAt: before)
        XCTAssertEqual(kept([finished]), [])
    }

    func testASessionAtOneHundredPercentWithNoFinishedMarkNoLongerCounts() {
        XCTAssertEqual(kept([session("full", percent: 100, createdAt: before, updatedAt: before)]), [])
    }

    func testASessionWithAFinishedStatusOrPhaseAloneNoLongerCounts() {
        XCTAssertEqual(kept([session("status", percent: 80, status: "finished", createdAt: before, updatedAt: before)]), [])
        XCTAssertEqual(kept([session("phase", percent: 80, phase: .finished, createdAt: before, updatedAt: before)]), [])
    }

    func testASessionAtNinetyNineUnfinishedNoLongerCounts() {
        XCTAssertEqual(kept([session("near-end", percent: 99, createdAt: before, updatedAt: before)]), [],
                       "Continue would resume near its end, and a few seconds finish the item again")
    }

    func testASessionPartWayKeepsItsPlace() {
        XCTAssertEqual(kept([session("forty", percent: 40, createdAt: before, updatedAt: before)]), ["forty"])
        XCTAssertEqual(kept([session("ninety-eight", percent: 98, createdAt: before, updatedAt: before)]), ["ninety-eight"])
    }

    func testAnItemNeverStartedHasNoSessionsToKeep() {
        XCTAssertEqual(kept([]), [])
    }

    // MARK: Neighbours

    func testAnItemNeverAddedAgainReturnsEverySession() {
        let sessions = [
            session("done", percent: 100, status: "finished", phase: .finished, createdAt: before, updatedAt: before, completedAt: before),
            session("near-end", percent: 99, createdAt: before, updatedAt: before),
            session("forty", percent: 40, createdAt: before, updatedAt: before),
        ]
        XCTAssertEqual(ids(ItemFinishedRule.continuationSessions(item(addedAgainAt: nil), sessions: sessions)), ["done", "near-end", "forty"])
        XCTAssertEqual(ids(ItemFinishedRule.continuationSessions(addedAgainAt: nil, sessions: sessions)), ["done", "near-end", "forty"])
    }

    func testAnOlderFinishedSessionAndANewerPartWayOneLeaveThePartWayOneToDecide() {
        let sessions = [
            session("done", percent: 100, status: "finished", phase: .finished, createdAt: before, updatedAt: before, completedAt: before),
            session("again", percent: 40, createdAt: after, updatedAt: after),
        ]
        XCTAssertEqual(kept(sessions), ["again"])
    }

    func testAFinishedSessionHeardAfterTheReAddStillCounts() {
        let finishedAgain = session("done-again", percent: 100, status: "finished", phase: .finished,
                                    createdAt: after, updatedAt: after, completedAt: after)
        XCTAssertEqual(kept([finishedAgain]), ["done-again"], "finishing the new pass makes the item finished again")
    }

    func testASessionWhoseLastListeningEqualsTheStampIsBefore() {
        let atTheStamp = session("at-stamp", percent: 100, status: "finished", phase: .finished,
                                 createdAt: before, updatedAt: addedAgain, completedAt: addedAgain)
        XCTAssertEqual(kept([atTheStamp]), [], "the same comparison `countedSessions` makes: after, not at")
    }

    func testAFinishedSessionTheEngineSavedAgainWhileClosingStaysLeftOut() {
        // Closing a finished session moves its `updatedAt` after the re-add and nothing else; its `completedAt` says
        // when the listening ended.
        let closedLater = session("closed", percent: 100, status: "finished", phase: .finished,
                                  createdAt: before, updatedAt: after, completedAt: before)
        XCTAssertEqual(kept([closedLater]), [])
    }

    func testASessionWithNoTimesIsBeforeTheReAdd() {
        XCTAssertEqual(kept([session("old-done", percent: 100, status: "finished", phase: .finished)]), [], "finished: left out")
        XCTAssertEqual(kept([session("old-forty", percent: 40)]), ["old-forty"], "part way: kept")
    }

    func testTwoReAddsTheLaterStampWins() {
        let sessions = [
            session("first-pass", percent: 100, status: "finished", phase: .finished, createdAt: before, updatedAt: before, completedAt: before),
            session("second-pass", percent: 100, status: "finished", phase: .finished, createdAt: after, updatedAt: after, completedAt: after),
        ]
        XCTAssertEqual(kept(sessions), ["second-pass"], "the first re-add leaves only the second pass")
        XCTAssertEqual(kept(sessions, addedAgainAt: after.addingTimeInterval(60)), [], "a later re-add leaves neither")
    }

    func testTheItemFormAndTheDateFormAgree() {
        let sessions = [
            session("done", percent: 100, status: "finished", phase: .finished, createdAt: before, updatedAt: before, completedAt: before),
            session("forty", percent: 40, createdAt: before, updatedAt: before),
        ]
        XCTAssertEqual(ids(ItemFinishedRule.continuationSessions(item(addedAgainAt: addedAgain), sessions: sessions)),
                       ids(ItemFinishedRule.continuationSessions(addedAgainAt: addedAgain, sessions: sessions)))
    }

    /// The row's "finished" test counts these the same way as `continuationSessions`: a session `itemAlreadyListened`
    /// calls listened is the one the rule leaves out when it ended before the re-add.
    func testTheRuleLeavesOutExactlyWhatPreparationCallsListened() {
        let candidates = [
            session("a", percent: 100, status: "finished", phase: .finished, createdAt: before, updatedAt: before, completedAt: before),
            session("b", percent: 100, createdAt: before, updatedAt: before),
            session("c", percent: 99, createdAt: before, updatedAt: before),
            session("d", percent: 98, createdAt: before, updatedAt: before),
            session("e", percent: 1, createdAt: before, updatedAt: before),
        ]
        for candidate in candidates {
            let listened = PreparationChunkGate.itemAlreadyListened([candidate])
            XCTAssertEqual(kept([candidate]).isEmpty, listened, "\(candidate.id): percent \(candidate.completionPercent)")
        }
    }
}
