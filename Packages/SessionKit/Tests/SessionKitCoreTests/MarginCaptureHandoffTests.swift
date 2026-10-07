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
