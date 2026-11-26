import Foundation
import XCTest
@testable import SessionKit

/// Hear it land's moment, its card run and the cards it leaves behind (#4713, the visible PR).
final class HearItLandAftermathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let target = MarginMomentAnchor(marginId: "s1::m1", mediaTimeMs: 252_000)

    // MARK: the moment (hearItLandSequenceEndsAfterVoice)

    func testTheSequenceUsesTheFiveSecondLeadInAndNoOtherMargins() {
        let sequence = HearItLand.sequence(itemId: "item", target: target)
        XCTAssertEqual(sequence.startMediaTimeMs, 247_000)
        XCTAssertEqual(sequence.unplayed, [target], "only the new Margin: an own Margin further on would keep the card")
    }

    func testAfterTheVoiceTheSequenceIsListeningWithNothingUnplayed() {
        var sequence = HearItLand.sequence(itemId: "item", target: target)
        _ = sequence.jumpToTarget()
        _ = sequence.marginFinished(sourceAtMediaTimeMs: 252_000)
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertTrue(sequence.unplayed.isEmpty, "the model ends the moment on this, so the card goes (Gate1AppModel.swift onChange)")
    }

    func testTheNarratedTextLimitIsPassedThrough() {
        let sequence = HearItLand.sequence(itemId: "item", target: target, tickAdvanceLimitMs: 1_234)
        XCTAssertEqual(sequence.tickAdvanceLimitMs, 1_234)
    }

    // MARK: the card's run

    func testOnlyTheMarginThatBeganIsTheHearItLandRun() {
        var aftermath = HearItLandAftermath()
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0), .moment)
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0), .hearItLand)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::other", now: t0), .moment, "another Margin's moment keeps its ordinary card")
    }

    func testTheRunEndsWithTheVoice() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(36))
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0), .moment, "Play this moment later is an ordinary moment")
    }

    func testTheLeadInCardWordsAreTheDesigns() {
        let card = PinnedMarginCard(subject: .yours, stage: .comingUp(msRemaining: 5_000), run: .hearItLand)
        XCTAssertEqual(card.headline, "Your Margin in 0:05")
        XCTAssertEqual(card.detail, "That's yours now, pinned to this moment.")
    }

    // MARK: the window after the playback (answerSavedWindowStartsAfterHearItLand)

    func testTheVoiceEndingStartsTheAnswerSavedWindow() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertNil(aftermath.playbackEndedAt)
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(40))
        XCTAssertEqual(aftermath.playbackEndedAt, t0.addingTimeInterval(40))
    }

    func testAnotherMarginsVoiceEndingChangesNothing() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        aftermath.voiceEnded(identity: "s1::friend", at: t0.addingTimeInterval(10))
        XCTAssertNil(aftermath.playbackEndedAt)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0), .hearItLand, "still waiting for its own voice")
    }

    func testAnAbandonedPlaybackDoesNotReopenTheWindowWhenItIsPlayedLater() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(HearItLandAftermath.playbackSpan + 1))
        XCTAssertNil(aftermath.playbackEndedAt)
    }

    func testTheEndCountsOnce() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(40))
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(500))
        XCTAssertEqual(aftermath.playbackEndedAt, t0.addingTimeInterval(40))
    }

    // MARK: a cancelled playback leaves no line behind

    func testACancelledPlaybackLeavesNoHearItLandLineForALaterPlayThisMoment() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertTrue(aftermath.cancelled(), "a playback was running")
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0.addingTimeInterval(5)), .moment)
        XCTAssertNil(aftermath.playbackEndedAt, "a cancel is not an end: the friend's window does not start")
        XCTAssertFalse(aftermath.cancelled(), "nothing left to cancel")
    }

    func testAMomentThatEndedItsVoiceHasNothingLeftToCancel() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertTrue(aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(20)))
        XCTAssertFalse(aftermath.cancelled(), "the speech ask is told once, at the voice's end")
        XCTAssertEqual(aftermath.playbackEndedAt, t0.addingTimeInterval(20), "ending the moment later keeps the window")
    }

    func testTheRunIgnoresAPlaybackOlderThanTheSpan() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        let late = t0.addingTimeInterval(HearItLandAftermath.playbackSpan + 1)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: late), .moment, "a playback that never reported its end")
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1", now: t0.addingTimeInterval(HearItLandAftermath.playbackSpan)), .hearItLand)
    }

    func testAnotherMarginsEndReportsNothingToTheSpeechAsk() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertFalse(aftermath.voiceEnded(identity: "s1::friend", at: t0.addingTimeInterval(3)))
    }

    // MARK: finding the saved Margin (the lookup the model used to do inline)

    private func margin(id: String, createdAt: Date, spoken: Bool = true, audio: String? = "interjections/a.m4a", ms: Int? = 252_000) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "s1", targetType: .item, targetId: "item", createdAt: createdAt, roughPercent: 50,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
            audioPath: audio, audioStatus: "recorded", transcriptionStatus: "pending", transcript: nil, cleanedTranscript: nil,
            displayText: spoken ? nil : "typed", status: "active")
    }

    func testTheSavedMarginIsFoundOnlyWhenItIsRecentAndPlaceable() throws {
        let fresh = margin(id: "m1", createdAt: t0.addingTimeInterval(-2))
        let old = margin(id: "m0", createdAt: t0.addingTimeInterval(-60))
        let noAudio = margin(id: "m2", createdAt: t0, audio: nil)
        let noPlace = margin(id: "m3", createdAt: t0, ms: nil)
        let all = [old, fresh, noAudio, noPlace]
        func find(_ id: String, at ms: Int? = 252_000) -> HearItLand.SavedPlayback? {
            HearItLand.savedPlayback(savedId: id, among: all, now: t0, clock: .media, targetMediaTimeMs: ms, textForItem: { _ in "" })
        }
        let found = try XCTUnwrap(find("m1"))
        XCTAssertEqual(found.saved.id, "m1")
        XCTAssertEqual(found.target.mediaTimeMs, 252_000)
        XCTAssertNil(find("m0"), "an id left behind by an earlier save must not play an older Margin")
        XCTAssertNil(find("m2"), "no recording to play")
        XCTAssertNil(find("m3", at: nil), "no place on the clock")
        XCTAssertNil(find("missing"))
    }

    // MARK: the written card (writtenWhilePausedShowsCard, the card itself)

    func testAWrittenMarginShowsItsCardFor45SecondsOnItsItem() throws {
        var aftermath = HearItLandAftermath()
        aftermath.wrote(itemId: "item", atMs: 252_000, at: t0)
        let card = try XCTUnwrap(aftermath.writtenCard(now: t0.addingTimeInterval(44), itemId: "item"))
        XCTAssertEqual(card.headline, "Your Margin is saved at 4:12")
        XCTAssertEqual(card.detail, "That's yours now, pinned to this moment.")
        XCTAssertTrue(card.actions.isEmpty, "no buttons")
        XCTAssertNil(aftermath.writtenCard(now: t0.addingTimeInterval(45), itemId: "item"))
        XCTAssertNil(aftermath.writtenCard(now: t0.addingTimeInterval(1), itemId: "other-item"))
    }

    func testAWrittenMarginOnTextLeavesOutTheTime() throws {
        var aftermath = HearItLandAftermath()
        aftermath.wrote(itemId: "item", atMs: nil, at: t0)
        let card = try XCTUnwrap(aftermath.writtenCard(now: t0, itemId: "item"))
        XCTAssertEqual(card.headline, "Your Margin is saved")
    }

    // MARK: a second playback replaces the first

    /// The app's sequence for a second save during the lead-in, counting how often the speech ask is told the playback ended:
    /// `replaced()`, the first moment's cancel (`cancelled()`), the second `began`, the second voice's end.
    func testASecondPlaybackTellsTheSpeechAskOnceNotTwice() {
        var aftermath = HearItLandAftermath()
        var told = 0
        aftermath.began(identity: "s1::m1", at: t0)

        aftermath.replaced()
        if aftermath.cancelled() { told += 1 }
        XCTAssertEqual(told, 0, "the replaced playback is forgotten quietly, so the card is not let out early")
        aftermath.began(identity: "s1::m2", at: t0.addingTimeInterval(1))
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m2", now: t0.addingTimeInterval(1)), .hearItLand)

        XCTAssertFalse(aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(2)), "the first's voice is no longer this run's")
        if aftermath.voiceEnded(identity: "s1::m2", at: t0.addingTimeInterval(6)) { told += 1 }
        XCTAssertEqual(told, 1, "once per playback: only the second one's end")
    }

    func testIsPlayingFollowsTheRun() {
        var aftermath = HearItLandAftermath()
        XCTAssertFalse(aftermath.isPlaying)
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertTrue(aftermath.isPlaying)
        aftermath.replaced()
        XCTAssertFalse(aftermath.isPlaying)
        aftermath.began(identity: "s1::m2", at: t0)
        _ = aftermath.voiceEnded(identity: "s1::m2", at: t0)
        XCTAssertFalse(aftermath.isPlaying)
    }
}
