import Foundation
import XCTest
@testable import SessionKit

/// #866: Add Margin while a Margin plays records at the playing Margin's place, not where the source paused after it.
final class MarginCaptureHandoffTests: XCTestCase {
    private func snapshot(itemId: String?, mediaTimeMs: Int? = nil, textStart: Int? = nil) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.itemId = itemId
        snapshot.currentMediaTimeMs = mediaTimeMs
        snapshot.currentTextStart = textStart
        return snapshot
    }

    func testThePlayingMomentMarginKnowsItsPlaceUntilItFinishes() {
        let target = MarginMomentAnchor(marginId: "ij-003", mediaTimeMs: 120_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 200_000)
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [later])
        XCTAssertNil(sequence.playing, "nothing plays during the lead-in")
        XCTAssertEqual(sequence.progressed(from: 119_600, to: 120_100), target)
        XCTAssertEqual(sequence.playing, target, "the source paused at 120.1 s; the Margin sits at 120 s")
        sequence.marginFinished()
        XCTAssertNil(sequence.playing)
        XCTAssertEqual(sequence.progressed(from: 199_900, to: 200_300), later)
        XCTAssertEqual(sequence.playing, later)
        sequence.marginFinished()
        XCTAssertNil(sequence.playing)

        var jumped = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertEqual(jumped.jumpToTarget(), target)
        XCTAssertEqual(jumped.playing, target, "Play it now")
    }

    /// Neighbouring inputs: the source just past, before, exactly at the Margin; another item; no place; text.
    func testMovesTheSourceBackToThePlayingMarginOnlyWhenItBelongsHere() {
        let podcast = MarginCaptureHandoff(itemId: "ep", place: .media(ms: 120_000))
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 120_480)), .seekMedia(ms: 120_000),
                       "paused a tick after the Margin: the new Margin must not anchor after it")
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 45_000)), .seekMedia(ms: 120_000),
                       "opened from a list while the source was elsewhere")
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 120_000)), .stay)
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "other", mediaTimeMs: 10_000)), .stay,
                       "a Margin from another item never moves this source")
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: nil)), .stay)
        XCTAssertEqual(MarginCaptureHandoff(itemId: "ep", place: nil).sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 5_000)), .stay)
        XCTAssertEqual(MarginCaptureHandoff(itemId: nil, place: .media(ms: 1_000)).sourceMove(from: snapshot(itemId: nil)), .stay)

        let article = MarginCaptureHandoff(itemId: "article", place: .text(charOffset: 120))
        XCTAssertEqual(article.sourceMove(from: snapshot(itemId: "article", textStart: 160)), .seekText(charOffset: 120))
        XCTAssertEqual(article.sourceMove(from: snapshot(itemId: "article", textStart: 120)), .stay)
    }

    /// The audit's case: the source paused at 120 s, your Margin at 60 s heard from its detail sheet.
    func testYourOwnMarginsPlaceIsWhereItWasRecorded() {
        func margin(_ anchor: Anchor, item: String = "ep") -> Interjection {
            Interjection(
                id: "ij-001", itemId: item, sessionId: "session-1", targetType: .item, targetId: item,
                createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: anchor, audioPath: nil,
                audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
                displayText: "A Margin", status: "active"
            )
        }
        let spoken = MarginCaptureHandoff(localMargin: margin(Anchor(
            anchorType: .transcript, startChar: 900, endChar: 940, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000)))
        XCTAssertEqual(spoken, MarginCaptureHandoff(itemId: "ep", place: .media(ms: 60_000)))
        XCTAssertEqual(spoken.sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 120_000)), .seekMedia(ms: 60_000),
                       "the new Margin anchors at the heard Margin, not where the source paused")
        XCTAssertEqual(spoken.sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 60_000)), .stay)
        XCTAssertEqual(spoken.sourceMove(from: snapshot(itemId: "other", mediaTimeMs: 120_000)), .stay,
                       "a Margin from another item never moves this source")

        let written = MarginCaptureHandoff(localMargin: margin(
            Anchor(anchorType: .text, startChar: 120, endChar: 140, anchorBefore: "", anchorAfter: ""), item: "article"))
        XCTAssertEqual(written.place, .text(charOffset: 120))
        XCTAssertEqual(written.sourceMove(from: snapshot(itemId: "article", textStart: 400)), .seekText(charOffset: 120))

        XCTAssertNil(MarginCaptureHandoff(localMargin: margin(
            Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: ""))).place,
            "a media anchor without a time has no place to go to")
        XCTAssertNil(MarginCaptureHandoff(localMargin: margin(
            Anchor(anchorType: .turn, startChar: 30, endChar: 50, anchorBefore: "", anchorAfter: "", turnSegmentIndex: 1))).place,
            "a conversation turn's place is relative to that turn")
    }

    func testASharedMarginsPlaceIsItsLocalPositionInThisCopy() {
        func shared(_ resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(id: "note", layerId: "layer", packageScopedId: "note", createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
                resolution: resolution)
        }
        let podcast = shared(ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 61_000, confidence: 1))
        XCTAssertEqual(MarginCaptureHandoff(sharedMargin: podcast, itemId: "ep"), MarginCaptureHandoff(itemId: "ep", place: .media(ms: 61_000)))
        let article = shared(ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 120, localEndChar: 140, confidence: 1))
        XCTAssertEqual(MarginCaptureHandoff(sharedMargin: article, itemId: "a").place, .text(charOffset: 120))
        let unplaced = shared(ImportedAnchorResolution(evidenceClass: .unresolved, confidence: 0))
        XCTAssertNil(MarginCaptureHandoff(sharedMargin: unplaced, itemId: "ep").place)
        XCTAssertEqual(MarginCaptureHandoff(sharedMargin: unplaced, itemId: "ep").sourceMove(from: snapshot(itemId: "ep", mediaTimeMs: 9_000)), .stay)

        var moment = MarginMomentSequence(itemId: "ep", target: MarginMomentAnchor(marginId: "m", mediaTimeMs: 7_000), otherMargins: [])
        XCTAssertNil(MarginCaptureHandoff(moment: moment).place, "nothing to hand off during the lead-in")
        _ = moment.jumpToTarget()
        XCTAssertEqual(MarginCaptureHandoff(moment: moment), MarginCaptureHandoff(itemId: "ep", place: .media(ms: 7_000)))
    }
}
