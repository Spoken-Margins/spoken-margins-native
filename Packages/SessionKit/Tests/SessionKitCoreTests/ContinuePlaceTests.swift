import Foundation
import XCTest
@testable import SessionKit

/// #4097: Continue on an episode the listener had listened to the end of, after a friend's packet was imported,
/// resumed at the end and skipped every Margin without asking. The place Continue starts at was worked out in three
/// places that disagreed; it is now one rule in SessionKit, and Continue asks about the Margins that rule puts behind.
final class ContinuePlaceTests: XCTestCase {
    private let end = 1_800_000

    private func session(
        _ id: String, status: String = "in_progress", phase: SessionPhase = .itemPlayback, percent: Int,
        mediaTimeMs: Int? = nil, charOffset: Int = 0, updated: TimeInterval
    ) -> Session {
        Session(
            id: id, itemId: "item", updatedAt: Date(timeIntervalSince1970: updated), status: status, phase: phase,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: charOffset, mediaTimeMs: mediaTimeMs),
            completionPercent: percent, playbackRate: 1)
    }

    private func friendsMargins() -> [SharedMarginReview.Entry] {
        let layer = ImportedCommentaryLayer(
            id: "ana", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: end),
            displayLabel: "Ana", importedAt: Date(timeIntervalSince1970: 1), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false)
        let records = [120_000, 600_000, 1_500_000].enumerated().map { index, ms in
            ImportedCommentaryInterjection(
                id: "m\(index)", layerId: "ana", packageScopedId: "m\(index)", createdAt: Date(timeIntervalSince1970: 1),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
                audioPath: "ImportedCommentary/m\(index).m4a", audioDurationMs: 4_000,
                resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 1))
        }
        return SharedMarginReview.entries(layers: [layer], records: ["ana": records])
    }

    /// The row the Library draws for `sessions`, as `LibraryRowBuilder` builds it.
    private func row(_ sessions: [Session]) throws -> LibraryItemRow {
        let item = Item(id: "item", title: "Episode", mediaType: "podcast", text: nil, externalReference: nil, status: "ready")
        let snapshot = LibraryReadSnapshot(items: [item], sessions: sessions, manifests: [], jobs: [], downloads: [])
        let context = StartupAudioContext(
            hasAcceptedCurrentTerms: true, hasSupertonicVoice: true, suppressedItemIds: [], liveSpeechFallbackItemIds: [],
            failedItemIds: [], preparingItemId: nil, playingItemId: nil, renderSignature: nil, allowsRendering: true)
        return try XCTUnwrap(LibraryRowBuilder.rows(from: snapshot, context: context).first)
    }

    func testContinueResumesAnythingNotFinished() {
        XCTAssertTrue(SessionContinuation.continueResumes(session("a", percent: 0, updated: 1)))
        XCTAssertTrue(SessionContinuation.continueResumes(session("b", percent: 99, updated: 1)), "99% is still resumed, at its end")
        XCTAssertFalse(SessionContinuation.continueResumes(session("c", percent: 100, updated: 1)))
        XCTAssertFalse(SessionContinuation.continueResumes(session("d", status: "finished", phase: .finished, percent: 40, updated: 1)))
        XCTAssertFalse(SessionContinuation.continueResumes(session("e", phase: .finished, percent: 40, updated: 1)))
        XCTAssertFalse(SessionContinuation.continueResumes(session("f", status: "finished", percent: 40, updated: 1)))
    }

    /// Where Continue lands, session by session: the saved place when it resumes, 0 when it begins again, and nil
    /// (don't assume) when it resumes somewhere the media time doesn't say.
    func testContinuePlaceFollowsTheSessionContinueResumes() {
        let table: [(String, [Session], Int?)] = [
            ("no sessions", [], 0),
            ("in progress at 12 min", [session("a", percent: 40, mediaTimeMs: 720_000, updated: 1)], 720_000),
            ("left at the end, 99%", [session("a", percent: 99, mediaTimeMs: end, updated: 1)], end),
            ("finished, replays from 0", [session("a", status: "finished", phase: .finished, percent: 100, mediaTimeMs: end, updated: 1)], 0),
            ("older finished, newer in progress", [
                session("old", status: "finished", phase: .finished, percent: 100, mediaTimeMs: end, updated: 1),
                session("new", percent: 30, mediaTimeMs: 540_000, updated: 2)], 540_000),
            ("newer finished, older in progress", [
                session("old", percent: 30, mediaTimeMs: 540_000, updated: 1),
                session("new", status: "finished", phase: .finished, percent: 100, mediaTimeMs: end, updated: 2)], 0),
            ("abandoned only", [session("a", phase: .abandoned, percent: 50, mediaTimeMs: 900_000, updated: 1)], 0),
            ("resumed, no media time, placed in the text", [session("a", percent: 50, charOffset: 4_000, updated: 1)], nil),
            ("resumed, no media time, at the start", [session("a", percent: 0, updated: 1)], 0),
        ]
        for (name, sessions, expected) in table {
            XCTAssertEqual(SessionContinuation.continuePlaceMs(sessions: sessions), expected, name)
        }
    }

    /// The row holds no place, so it says so, except where Continue plainly starts at 0. The old rule read "completed"
    /// as "starts at 0", and a row is completed at 99% and after any earlier finished session.
    func testARowOnlyStartsAtZeroWhenContinueBeginsAgain() throws {
        let table: [(String, [Session], Int?)] = [
            ("never listened", [], 0),
            ("in progress", [session("a", percent: 40, mediaTimeMs: 720_000, updated: 1)], nil),
            ("left at the end, 99%", [session("a", percent: 99, mediaTimeMs: end, updated: 1)], nil),
            ("finished", [session("a", status: "finished", phase: .finished, percent: 100, updated: 1)], 0),
            ("earlier finished session, newer one in progress", [
                session("old", status: "finished", phase: .finished, percent: 100, updated: 1),
                session("new", percent: 90, mediaTimeMs: 1_600_000, updated: 2)], nil),
        ]
        for (name, sessions, expected) in table {
            XCTAssertEqual(try row(sessions).continuePlaceMs, expected, name)
        }
        let nearlyDone = try row([session("a", percent: 99, mediaTimeMs: end, updated: 1)])
        XCTAssertTrue(nearlyDone.isCompleted, "the row calls a 99% episode completed, which is why completed can't mean 'starts at 0'")
        XCTAssertTrue(nearlyDone.hasContinuationSession)
    }

    /// The owner's case: a friend's reply imported into a podcast left at its end. Continue, from the Library row or
    /// the open item, must find the Margins behind the place; it may only skip the question where Continue starts over
    /// or the Margins are still ahead.
    func testContinueAsksAboutMarginsBehindAnEpisodeLeftAtItsEnd() throws {
        let margins = friendsMargins()
        XCTAssertEqual(margins.count, 3)
        let atTheEnd = [session("a", percent: 99, mediaTimeMs: end, updated: 1)]
        let fromTheRow = try SharedMarginReview.entriesBehind(margins, placeMs: row(atTheEnd).continuePlaceMs)
        let fromTheOpenItem = SharedMarginReview.entriesBehind(margins, placeMs: SessionContinuation.continuePlaceMs(sessions: atTheEnd))
        XCTAssertEqual(fromTheRow.count, 3, "every Margin is behind the end, so the listener is asked")
        XCTAssertEqual(fromTheOpenItem.count, 3)

        let finished = [session("a", status: "finished", phase: .finished, percent: 100, mediaTimeMs: end, updated: 1)]
        XCTAssertTrue(try SharedMarginReview.entriesBehind(margins, placeMs: row(finished).continuePlaceMs).isEmpty,
                      "Replay starts at 0 and the Margins play in place")

        let partway = [session("a", percent: 30, mediaTimeMs: 540_000, updated: 1)]
        XCTAssertEqual(
            SharedMarginReview.entriesBehind(margins, placeMs: SessionContinuation.continuePlaceMs(sessions: partway)).map(\.interjection.id),
            ["m0"], "only the Margin the listener is past is asked about")
    }
}
