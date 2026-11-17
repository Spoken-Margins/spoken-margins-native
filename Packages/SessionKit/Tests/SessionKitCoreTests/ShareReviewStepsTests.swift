import XCTest
@testable import SessionKit

/// The share review's waits (#3839): every evidence status, playing or not, one Margin or several.
final class ShareReviewStepsTests: XCTestCase {
    private func margin(
        audio: Bool = true, evidence: Bool = false, status: PodcastAnchorEvidenceCaptureStatus? = nil,
        words: String = "transcribed", playing: Bool = false
    ) -> ShareReviewSteps.Margin {
        .init(isNativeAudio: audio, hasEvidence: evidence, evidenceStatus: status, transcriptionStatus: words, playingThisItem: playing)
    }

    func testAMarginWaitingOnItsMomentShowsTheStepThatMatchesWhetherTheEpisodePlays() {
        let playing = ShareReviewSteps.cardSteps(margin(status: .pendingPostResumeSample, playing: true))
        XCTAssertEqual(playing, [.init(icon: .clock, text: "Finding the exact moment for this Margin. Keep the episode playing a few more seconds.")])
        let paused = ShareReviewSteps.cardSteps(margin(status: .pendingPostResumeSample, playing: false))
        XCTAssertEqual(paused.first?.icon, .clock)
        XCTAssertTrue(paused.first?.text.hasPrefix("Play the episode for about 12 seconds") == true)
        XCTAssertTrue(paused.first?.text.hasSuffix("Sharing now may put it a few seconds off.") == true)
    }

    func testNoOtherEvidenceStatusIsAStepAndTheNoteReadsByStatus() {
        for status in [PodcastAnchorEvidenceCaptureStatus.ready, .unavailable, .pendingExactLocalCapture, nil] {
            XCTAssertEqual(ShareReviewSteps.cardSteps(margin(status: status)), [], "\(String(describing: status))")
        }
        XCTAssertEqual(ShareReviewSteps.cardNote(margin(status: .pendingExactLocalCapture)), "Getting the exact moment ready for this Margin.")
        let byWords = "Your friend's copy will find this Margin by its words, so it may land a few seconds off."
        XCTAssertEqual(ShareReviewSteps.cardNote(margin(status: .unavailable)), byWords)
        XCTAssertEqual(ShareReviewSteps.cardNote(margin(status: nil)), byWords)
        XCTAssertNil(ShareReviewSteps.cardNote(margin(status: .ready)))
        XCTAssertNil(ShareReviewSteps.cardNote(margin(status: .pendingPostResumeSample)), "the step says it")
    }

    func testEvidenceAlreadyOnTheMarginGivesNothingWhateverItsStatus() {
        for status in [PodcastAnchorEvidenceCaptureStatus.pendingPostResumeSample, .pendingExactLocalCapture, .unavailable, .ready, nil] {
            let m = margin(evidence: true, status: status)
            XCTAssertEqual(ShareReviewSteps.cardSteps(m), [])
            XCTAssertNil(ShareReviewSteps.cardNote(m))
            XCTAssertNil(ShareReviewSteps.pinnedLine([m]))
        }
    }

    func testAnArticleOrPDFMarginGivesNothing() {
        let m = margin(audio: false, status: .pendingPostResumeSample)
        XCTAssertEqual(ShareReviewSteps.cardSteps(m), [])
        XCTAssertNil(ShareReviewSteps.cardNote(m))
        XCTAssertNil(ShareReviewSteps.pinnedLine([m]))
    }

    func testThePinnedLineByCountAndPlayback() {
        let one = margin(status: .pendingPostResumeSample, playing: true)
        XCTAssertEqual(ShareReviewSteps.pinnedLine([one]),
            "Finding the exact moment for your new Margin. Keep the episode playing a few more seconds.")
        XCTAssertEqual(ShareReviewSteps.pinnedLine([one, one, margin()]),
            "Finding the exact moment for 2 of these Margins. Keep the episode playing a few more seconds.")
        var paused = one
        paused.playingThisItem = false
        XCTAssertEqual(ShareReviewSteps.pinnedLine([paused]),
            "Play the episode for about 12 seconds so your friend hears your new Margin at the exact moment. Sharing now may put it a few seconds off.")
        XCTAssertEqual(ShareReviewSteps.pinnedLine([paused, paused]),
            "Play the episode for about 12 seconds so your friend hears 2 of these Margins at the exact moment. Sharing now may put them a few seconds off.")
        XCTAssertNil(ShareReviewSteps.pinnedLine([margin(), margin(status: .ready)]))
        XCTAssertNil(ShareReviewSteps.pinnedLine([]))
    }

    func testAMarginWaitingOnItsWordsHasAStepABadgeAndTheWordsLine() {
        let m = margin(status: .pendingPostResumeSample, words: "pending")
        XCTAssertEqual(ShareReviewSteps.badge(m), "Waiting for words")
        XCTAssertEqual(ShareReviewSteps.cardSteps(m).map(\.icon), [.words, .clock], "words first, then the moment")
        XCTAssertEqual(ShareReviewSteps.cardSteps(margin(words: "pending")),
            [.init(icon: .words, text: "Getting this Margin's words ready. It's added when they're ready.")])
        XCTAssertEqual(ShareReviewSteps.pinnedLine([margin(words: "pending")]),
            "Getting the words ready for your new Margin. A few seconds.")
    }

    func testBothWaitsAtOnceShowOnePinnedLineThatIsTheWordsLine() {
        let both = margin(status: .pendingPostResumeSample, words: "pending", playing: true)
        XCTAssertEqual(ShareReviewSteps.pinnedLine([both]), "Getting the words ready for your new Margin. A few seconds.")
        XCTAssertEqual(ShareReviewSteps.pinnedLine([both, both]), "Getting the words ready for 2 of these Margins. A few seconds.")
        // Words wait on one Margin, the moment on another: still the words line.
        XCTAssertEqual(ShareReviewSteps.pinnedLine([margin(words: "pending"), margin(status: .pendingPostResumeSample)]),
            "Getting the words ready for your new Margin. A few seconds.")
    }

    func testAFailedTranscriptKeepsTodaysLineAndBadgeAndShowsNoStep() {
        let m = margin(words: "failed")
        XCTAssertEqual(ShareReviewSteps.badge(m), "Left out: no transcript yet")
        XCTAssertEqual(ShareReviewSteps.cardSteps(m), [])
        XCTAssertNil(ShareReviewSteps.pinnedLine([m]))
        XCTAssertEqual(ShareReviewSteps.failedTranscriptLine,
            "No transcript yet, so this Margin can't be shared. Retry its transcription in Margin detail.")
        XCTAssertNil(ShareReviewSteps.badge(margin()))
    }
}
