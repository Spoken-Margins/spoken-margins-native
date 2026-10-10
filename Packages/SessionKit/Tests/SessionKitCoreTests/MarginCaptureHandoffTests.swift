import Foundation
import XCTest
@testable import SessionKit

/// #866: Add Margin while a Margin plays records at the playing Margin's place, not where the source paused after it.
final class MarginCaptureHandoffTests: XCTestCase {
    private func snapshot(itemId: String?, mediaTimeMs: Int? = nil, textStart: Int? = nil, target: TargetType? = nil, targetId: String? = nil, sessionId: String? = "session-1") -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = sessionId
        snapshot.itemId = itemId
        snapshot.targetType = target?.rawValue
        snapshot.targetId = targetId
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

    /// A place only moves a source that can show it. A conversation turn's position is relative to that turn, so an
    /// article place must not move it; live speech has no media clock; narration and podcasts take either seek.
    func testASourceThatCantShowThePlaceStaysWhereItIs() {
        let article = MarginCaptureHandoff(itemId: "a", place: .text(charOffset: 5_000))
        let podcast = MarginCaptureHandoff(itemId: "a", place: .media(ms: 60_000))
        for turn in [TargetType.assistantTurnTTS, .summaryTurnTTS] {
            XCTAssertEqual(article.sourceMove(from: snapshot(itemId: "a", textStart: 10, target: turn)), .stay, "\(turn)")
            XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 10, target: turn)), .stay, "\(turn)")
        }
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "a", textStart: 10, target: .itemTextTTS)), .stay,
                       "a Margin recorded on narration, heard while the article reads aloud as live speech")
        XCTAssertEqual(article.sourceMove(from: snapshot(itemId: "a", textStart: 10, target: .itemTextTTS)), .seekText(charOffset: 5_000))
        XCTAssertEqual(article.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 10, target: .transcriptBackedMedia)), .seekText(charOffset: 5_000),
                       "prepared narration plays as media; the engine finds the text place on its timeline")
        XCTAssertEqual(podcast.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 10, target: .transcriptBackedMedia)), .seekMedia(ms: 60_000))
    }

    private func margin(_ anchor: Anchor, item: String = "ep", target: InterjectionTargetType = .item, targetId: String? = nil) -> Interjection {
        Interjection(
            id: "ij-001", itemId: item, sessionId: "session-1", targetType: target, targetId: targetId ?? item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 10, anchor: anchor, audioPath: nil,
            audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A Margin", status: "active"
        )
    }

    /// The audit's case: the source paused at 120 s, your Margin at 60 s heard from its detail sheet.
    func testYourOwnMarginsPlaceIsWhereItWasRecorded() {
        let spoken = MarginCaptureHandoff(localMargin: margin(Anchor(
            anchorType: .transcript, startChar: 900, endChar: 940, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000)))
        XCTAssertEqual(spoken, MarginCaptureHandoff(itemId: "ep", place: .narration(ms: 60_000, charOffset: 900)))
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
            "a turn anchor on an item target has no turn to go back to")
    }

    /// The second audit's first case: a Margin recorded on narration at text 900, the article now reads aloud as live
    /// speech at 1800. Live speech has no media clock, so the text offset places it.
    func testANarrationMarginGoesByItsTextWhenTheArticleReadsAloud() {
        let heard = MarginCaptureHandoff(localMargin: margin(Anchor(
            anchorType: .transcript, startChar: 900, endChar: 940, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000), item: "a"))
        XCTAssertEqual(heard.sourceMove(from: snapshot(itemId: "a", textStart: 1_800, target: .itemTextTTS)), .seekText(charOffset: 900))
        XCTAssertEqual(heard.sourceMove(from: snapshot(itemId: "a", textStart: 900, target: .itemTextTTS)), .stay)
        XCTAssertEqual(heard.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 120_000, target: .transcriptBackedMedia)), .seekMedia(ms: 60_000),
                       "back on the narration it still goes by its media time")
        XCTAssertEqual(heard.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 60_000, target: .transcriptBackedMedia)), .stay)
        for turn in [TargetType.assistantTurnTTS, .summaryTurnTTS] {
            XCTAssertEqual(heard.sourceMove(from: snapshot(itemId: "a", textStart: 10, target: turn, targetId: "t")), .stay, "\(turn)")
        }
        // A media anchor, or a transcript anchor whose segment had no text positions (they resolve to 0...0), has no
        // article text to go by: live speech stays put rather than jumping to the article's start.
        for anchor in [
            Anchor(anchorType: .media, startChar: 900, endChar: 940, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000),
            Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000)
        ] {
            let noText = MarginCaptureHandoff(localMargin: margin(anchor, item: "a"))
            XCTAssertEqual(noText.place, .media(ms: 60_000), "\(anchor.anchorType)")
            XCTAssertEqual(noText.sourceMove(from: snapshot(itemId: "a", textStart: 1_800, target: .itemTextTTS)), .stay, "\(anchor.anchorType)")
            XCTAssertEqual(noText.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 120_000, target: .transcriptBackedMedia)), .seekMedia(ms: 60_000))
        }
    }

    /// The second audit's second case: the turn paused at character 1000, your Margin on that turn at 300.
    func testAMarginOnTheCurrentTurnMovesThatTurnToIt() {
        let onTurn = MarginCaptureHandoff(localMargin: margin(
            Anchor(anchorType: .turn, startChar: 300, endChar: 340, anchorBefore: "", anchorAfter: "", turnSegmentIndex: 2),
            item: "a", target: .assistantTurn, targetId: "turn-1"))
        XCTAssertEqual(onTurn.place, .turn(sessionId: "session-1", id: "turn-1", charOffset: 300))
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", textStart: 1_000, target: .assistantTurnTTS, targetId: "turn-1")), .seekText(charOffset: 300))
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", textStart: 300, target: .assistantTurnTTS, targetId: "turn-1")), .stay)
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", textStart: 1_000, target: .assistantTurnTTS, targetId: "turn-2")), .stay,
                       "another turn's text is a different place")
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", textStart: 1_000, target: .assistantTurnTTS, targetId: "turn-1", sessionId: "session-2")), .stay,
                       "turn ids repeat from one session to the next: the same id in another session is another turn")
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", textStart: 1_000, target: .itemTextTTS, targetId: "a")), .stay,
                       "the article isn't the turn")
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "a", mediaTimeMs: 5_000, target: .transcriptBackedMedia, targetId: "x")), .stay)
        XCTAssertEqual(onTurn.sourceMove(from: snapshot(itemId: "other", textStart: 1_000, target: .assistantTurnTTS, targetId: "turn-1")), .stay)

        let summary = MarginCaptureHandoff(localMargin: margin(
            Anchor(anchorType: .turn, startChar: 12, endChar: 30, anchorBefore: "", anchorAfter: "", turnSegmentIndex: 0),
            item: "a", target: .summaryTurn, targetId: "sum-1"))
        XCTAssertEqual(summary.sourceMove(from: snapshot(itemId: "a", textStart: 80, target: .summaryTurnTTS, targetId: "sum-1")), .seekText(charOffset: 12))
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
