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
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1"), .moment)
        aftermath.began(identity: "s1::m1", at: t0)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1"), .hearItLand)
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::other"), .moment, "another Margin's moment keeps its ordinary card")
    }

    func testTheRunEndsWithTheVoice() {
        var aftermath = HearItLandAftermath()
        aftermath.began(identity: "s1::m1", at: t0)
        aftermath.voiceEnded(identity: "s1::m1", at: t0.addingTimeInterval(36))
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1"), .moment, "Play this moment later is an ordinary moment")
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
        XCTAssertEqual(aftermath.run(forMomentTarget: "s1::m1"), .hearItLand, "still waiting for its own voice")
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
}
