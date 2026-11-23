import XCTest
@testable import SessionKit

/// The sender's "Before your Margin" row (#4171, PR 4b): the menu, its words, and what the preview plays.
final class SenderLeadInPreviewTests: XCTestCase {
    // MARK: The plan

    func testThePreviewStartsWhereTheFriendsReviewStartsWithTheSendersLength() {
        let plan = SenderLeadInPreview.Plan(marginPositionMs: 600_000, leadInMs: 60_000)
        XCTAssertEqual(plan.startMs, 540_000)
        XCTAssertEqual(plan.marginMs, 600_000)
        XCTAssertEqual(plan.runUpMs, 60_000)
        XCTAssertFalse(plan.reachedEpisodeStart)
        // The friend's review computes the same start from the same length (Design §2: `max(0, M − L)`).
        let friend = ListeningMoment(
            use: .reviewNewMargins, margin: .init(id: "m", position: 600_000, leadInMs: 60_000), source: .media())
        XCTAssertEqual(plan.startMs, friend.sourceStartPosition)
    }

    func testTwoCloseMarginsTheSecondsRunUpPassesTheFirstWithNoClamp() {
        // Two Margins 30 s apart, 1 min on the second (Design §6): the preview starts a minute before the second and
        // plays past the first, as the friend's plain moment would. It is never cut short at the first Margin.
        let first = 300_000, second = 330_000
        let plan = SenderLeadInPreview.Plan(marginPositionMs: second, leadInMs: 60_000)
        XCTAssertEqual(plan.startMs, 270_000)
        XCTAssertLessThan(plan.startMs, first)
        XCTAssertEqual(plan.runUpMs, 60_000)
    }

    func testAMarginNearTheStartBeginsAtZero() {
        let plan = SenderLeadInPreview.Plan(marginPositionMs: 10_000, leadInMs: 60_000)
        XCTAssertEqual(plan.startMs, 0)
        XCTAssertEqual(plan.runUpMs, 10_000)
        XCTAssertTrue(plan.reachedEpisodeStart)

        let atZero = SenderLeadInPreview.Plan(marginPositionMs: 0, leadInMs: 20_000)
        XCTAssertEqual(atZero.startMs, 0)
        XCTAssertEqual(atZero.runUpMs, 0)
    }

    func testALongEpisodesLateMarginKeepsItsWholeRunUp() {
        // `long-source`: 1:59:30 with 2 min starts at 1:57:30.
        let plan = SenderLeadInPreview.Plan(marginPositionMs: 7_170_000, leadInMs: 120_000)
        XCTAssertEqual(plan.startMs, 7_050_000)
    }

    func testTheDefaultLengthIsTwentySeconds() {
        let plan = SenderLeadInPreview.Plan(marginPositionMs: 100_000, leadInMs: SenderLeadIn.defaultMs)
        XCTAssertEqual(plan.startMs, 80_000)
    }

    func testALengthOutsideWhatAReaderAcceptsIsClampedAsTheFriendWouldClampIt() {
        XCTAssertEqual(SenderLeadInPreview.Plan(marginPositionMs: 1_000_000, leadInMs: 900_000).startMs, 700_000)
        XCTAssertEqual(SenderLeadInPreview.Plan(marginPositionMs: 1_000_000, leadInMs: -5).startMs, 1_000_000)
    }

    // MARK: The menu

    func testTheMenuOffersTheSevenLengthsInOrder() {
        XCTAssertEqual(SenderLeadInPreview.choicesMs(current: 20_000), [5_000, 10_000, 20_000, 30_000, 45_000, 60_000, 120_000])
        XCTAssertEqual(SenderLeadInPreview.choicesMs(current: 20_000).map(SenderLeadInPreview.choiceLabel), [
            "5 sec of the episode", "10 sec of the episode", "20 sec of the episode", "30 sec of the episode",
            "45 sec of the episode", "1 min of the episode", "2 min of the episode",
        ])
        XCTAssertTrue(SenderLeadInPreview.presetsMs.contains(SenderLeadIn.defaultMs))
    }

    func testARememberedLengthThatIsNoPresetIsListedSoTheMenuShowsWhatThePacketCarries() {
        XCTAssertEqual(SenderLeadInPreview.choicesMs(current: 90_000), [5_000, 10_000, 20_000, 30_000, 45_000, 60_000, 90_000, 120_000])
        XCTAssertEqual(SenderLeadInPreview.choiceLabel(90_000), "1 min 30 sec of the episode")
        // Beyond what a reader accepts it is listed at the clamp, the value the packet would carry.
        XCTAssertEqual(SenderLeadInPreview.choicesMs(current: 900_000).last, 300_000)
        XCTAssertEqual(SenderLeadInPreview.choiceLabel(300_000), "5 min of the episode")
        XCTAssertEqual(SenderLeadInPreview.choicesMs(current: 0).first, 0)
        XCTAssertEqual(SenderLeadInPreview.choiceLabel(0), "0 sec of the episode")
    }

    func testTheMenuStartsAtTheSameValueTheDraftStartsAt() {
        for lastSent in [nil, 0, 5_000, 60_000, 75_000, 400_000] as [Int?] {
            let start = SenderLeadIn.startingMs(lastSent: lastSent)
            XCTAssertTrue(SenderLeadInPreview.choicesMs(current: start).contains(start), "\(String(describing: lastSent))")
        }
    }

    // MARK: Words and availability

    func testWordsOnlyMarginsSayWhatTheFriendGetsAfterTheRunUp() {
        XCTAssertNil(SenderLeadInPreview.afterRunUpCaption(goesAsWords: false, readAloud: true))
        XCTAssertEqual(SenderLeadInPreview.afterRunUpCaption(goesAsWords: true, readAloud: true), "Then their phone reads your words.")
        XCTAssertEqual(SenderLeadInPreview.afterRunUpCaption(goesAsWords: true, readAloud: false), "Then they read your words.")
    }

    func testTheRowShowsOnlyForAPlacedMarginOnAnEpisode() {
        XCTAssertTrue(SenderLeadInPreview.showsRow(isNativeAudio: true, hasPlace: true, marginPositionMs: 0))
        XCTAssertFalse(SenderLeadInPreview.showsRow(isNativeAudio: false, hasPlace: true, marginPositionMs: 1_000))
        XCTAssertFalse(SenderLeadInPreview.showsRow(isNativeAudio: true, hasPlace: false, marginPositionMs: 1_000))
        XCTAssertFalse(SenderLeadInPreview.showsRow(isNativeAudio: true, hasPlace: true, marginPositionMs: nil))
    }

    func testThePreviewIsOffWhileTheMomentIsBeingFound() {
        let pending = ShareReviewSteps.Margin(
            isNativeAudio: true, hasEvidence: false, evidenceStatus: .pendingPostResumeSample,
            transcriptionStatus: "transcribed", playingThisItem: true)
        XCTAssertFalse(SenderLeadInPreview.previewIsAvailable(pending))
        for status: PodcastAnchorEvidenceCaptureStatus? in [nil, .ready, .unavailable, .pendingExactLocalCapture] {
            let margin = ShareReviewSteps.Margin(
                isNativeAudio: true, hasEvidence: false, evidenceStatus: status,
                transcriptionStatus: "transcribed", playingThisItem: false)
            XCTAssertTrue(SenderLeadInPreview.previewIsAvailable(margin), "\(String(describing: status))")
        }
    }
}
