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
        // One waiting Margin not playing is enough for the "Play the episode" line.
        XCTAssertEqual(ShareReviewSteps.pinnedLine([one, paused]),
            "Play the episode for about 12 seconds so your friend hears 2 of these Margins at the exact moment. Sharing now may put them a few seconds off.")
        XCTAssertNil(ShareReviewSteps.pinnedLine([margin(), margin(status: .ready)]))
        XCTAssertNil(ShareReviewSteps.pinnedLine([]))
    }

    func testAMarginWaitingOnItsWordsHasAStepABadgeAndTheWordsLine() {
        let m = margin(status: .pendingPostResumeSample, words: "pending")
        XCTAssertEqual(ShareReviewSteps.waitingBadge(m), "Waiting for words")
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

    /// A voice Margin whose transcription failed goes with placeholder words (#3027), so it has no badge and no step; the
    /// card's warning for a Margin with neither words nor voice is `SharedMarginTextRequirement.reviewWarningText`.
    func testAFailedTranscriptShowsNoStepAndNoWaitingBadge() {
        let m = margin(words: "failed")
        XCTAssertNil(ShareReviewSteps.waitingBadge(m))
        XCTAssertEqual(ShareReviewSteps.cardSteps(m), [])
        XCTAssertNil(ShareReviewSteps.pinnedLine([m]))
        XCTAssertNil(ShareReviewSteps.waitingBadge(margin()))
        for finished in ["transcribed", "complete"] {
            XCTAssertNil(ShareReviewSteps.waitingBadge(margin(words: finished)), finished)
        }
    }

    func testThePinnedStepCarriesTheIconOfTheWaitItNames() {
        let moment = margin(status: .pendingPostResumeSample, playing: true)
        XCTAssertEqual(ShareReviewSteps.pinnedStep([moment])?.icon, .clock)
        XCTAssertEqual(ShareReviewSteps.pinnedStep([moment])?.text, ShareReviewSteps.pinnedLine([moment]))
        XCTAssertEqual(ShareReviewSteps.pinnedStep([moment, margin(words: "pending")])?.icon, .words)
        XCTAssertNil(ShareReviewSteps.pinnedStep([margin()]))
    }

    // MARK: From a stored Margin

    private func stored(
        evidence: [CapturedPodcastAnchorEvidence]? = nil, status: PodcastAnchorEvidenceCaptureStatus? = nil,
        words: String = "ready"
    ) -> Interjection {
        .init(id: "m", itemId: "item", sessionId: "s", targetType: .item, targetId: "item", createdAt: Date(timeIntervalSince1970: 0),
              roughPercent: 10, anchor: .init(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
              audioPath: nil, audioStatus: "ready", transcriptionStatus: words, transcript: nil,
              cleanedTranscript: nil, displayText: nil, status: "ready",
              podcastAnchorEvidence: evidence, podcastAnchorEvidenceCaptureStatus: status)
    }

    private let oneEvidence = CapturedPodcastAnchorEvidence(id: "e", localPath: "/unused", durationMs: 12_000, anchorOffsetMs: 4_000)

    func testAStoredMarginReadsItsEvidenceNilAndEmptyAreTheSameAndNonEmptyGivesNothing() {
        for evidence in [nil, []] as [[CapturedPodcastAnchorEvidence]?] {
            let m = ShareReviewSteps.Margin(stored(evidence: evidence, status: .pendingPostResumeSample), isNativeAudio: true, playingThisItem: true)
            XCTAssertTrue(m.waitsOnMoment, "\(String(describing: evidence))")
            XCTAssertFalse(m.hasEvidence)
        }
        let withEvidence = ShareReviewSteps.Margin(
            stored(evidence: [oneEvidence], status: .pendingPostResumeSample), isNativeAudio: true, playingThisItem: true)
        XCTAssertTrue(withEvidence.hasEvidence)
        XCTAssertEqual(ShareReviewSteps.cardSteps(withEvidence), [])
        XCTAssertNil(ShareReviewSteps.pinnedLine([withEvidence]))
    }

    func testAStoredMarginOnAnArticleGivesNothing() {
        let m = ShareReviewSteps.Margin(stored(status: .pendingPostResumeSample), isNativeAudio: false, playingThisItem: false)
        XCTAssertEqual(ShareReviewSteps.cardSteps(m), [])
        XCTAssertNil(ShareReviewSteps.cardNote(m))
    }

    func testAStoredMarginPendingOnItsWordsWaitsAndClearsWhenTheyArrive() {
        var margin = stored(status: .pendingPostResumeSample, words: "pending")
        let waiting = ShareReviewSteps.Margin(margin, isNativeAudio: true, playingThisItem: true)
        XCTAssertEqual(ShareReviewSteps.waitingBadge(waiting), "Waiting for words")
        XCTAssertEqual(ShareReviewSteps.cardSteps(waiting).map(\.icon), [.words, .clock])
        margin.transcriptionStatus = "transcribed"
        let arrived = ShareReviewSteps.Margin(margin, isNativeAudio: true, playingThisItem: true)
        XCTAssertNil(ShareReviewSteps.waitingBadge(arrived))
        XCTAssertEqual(ShareReviewSteps.cardSteps(arrived).map(\.icon), [.clock])
    }

    func testAStepClearsWhenTheStoredMarginGainsEvidence() {
        var margin = stored(status: .pendingPostResumeSample)
        XCTAssertNotNil(ShareReviewSteps.pinnedLine([.init(margin, isNativeAudio: true, playingThisItem: true)]))
        margin.podcastAnchorEvidence = [oneEvidence]
        margin.podcastAnchorEvidenceCaptureStatus = .ready
        XCTAssertNil(ShareReviewSteps.pinnedLine([.init(margin, isNativeAudio: true, playingThisItem: true)]))
    }
}
