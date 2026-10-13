import XCTest
import SessionKit

/// One test per row of the "Shared Margin return claim" table in `docs/gate1-playback-transition-table.md`
/// (rows R01 to R16, R18 and R19; the other rows live in the model and name app-hosted tests). Each is named for its row.
final class SharedMarginReturnClaimTests: XCTestCase {
    // R01
    func testR01APromptShownWhileTheSourcePlaysHoldsThePromptsPart() {
        var claim = SharedMarginReturnClaim.none
        claim.promptShown(sourceWasPlaying: true)
        XCTAssertEqual(claim, .prompt)
    }

    // R02
    func testR02APromptShownWhileTheSourceWasNotPlayingReplacesAnEarlierPromptsPartAndKeepsTheVoices() {
        var claim = SharedMarginReturnClaim.promptAndVoice
        claim.promptShown(sourceWasPlaying: false)
        XCTAssertEqual(claim, .voice, "the new offer did not pause the source, so nothing is owed for it")

        var onlyPrompt = SharedMarginReturnClaim.prompt
        onlyPrompt.promptShown(sourceWasPlaying: false)
        XCTAssertEqual(onlyPrompt, .none)
    }

    // R03
    func testR03DismissingAPromptThatPausedTheSourceOwesTheSourceBackAndReleasesThePrompt() {
        var claim = SharedMarginReturnClaim.prompt
        XCTAssertTrue(claim.promptDismissed())
        XCTAssertEqual(claim, .none)
        XCTAssertFalse(claim.promptDismissed(), "a second dismissal cannot resume the source again")
    }

    // R04
    func testR04DismissingAPromptThatDidNotPauseTheSourceOwesNothing() {
        var claim = SharedMarginReturnClaim.none
        XCTAssertFalse(claim.promptDismissed())
        XCTAssertEqual(claim, .none)
    }

    // R05
    func testR05DismissingLeavesTheVoicesPartAlone() {
        var claim = SharedMarginReturnClaim.promptAndVoice
        XCTAssertTrue(claim.promptDismissed())
        XCTAssertEqual(claim, .voice)

        var voiceOnly = SharedMarginReturnClaim.voice
        XCTAssertFalse(voiceOnly.promptDismissed())
        XCTAssertEqual(voiceOnly, .voice)
    }

    // R06
    func testR06ListeningWhileTheSourcePlaysOwesTheSourceBack() {
        var claim = SharedMarginReturnClaim.none
        XCTAssertTrue(claim.listenRequested(sourceIsPlaying: true, voiceIsPlaying: false))
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: true)
        XCTAssertEqual(claim, .voice)
    }

    // R07
    func testR07ListeningAfterThePromptPausedTheSourceOwesItBackAndReleasesThePrompt() {
        var claim = SharedMarginReturnClaim.prompt
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: false)
        XCTAssertTrue(owed)
        XCTAssertEqual(claim, .none, "the prompt's part is released at capture, before the source is paused or stopped")
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .voice)
    }

    // R08
    func testR08ListeningToAPausedSourceWithNoPromptOwesNothing() {
        var claim = SharedMarginReturnClaim.none
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: false)
        XCTAssertFalse(owed)
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .none)
    }

    // R09
    func testR09ReplacingAVoiceThatHeldThePromiseKeepsThePromise() {
        var claim = SharedMarginReturnClaim.voice
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: true)
        XCTAssertTrue(owed, "captured before the common stop clears it")
        XCTAssertEqual(claim, .voice, "capture does not clear the voice's part; the common stop does")
        claim.voiceStopped()
        XCTAssertEqual(claim, .none)
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .voice)
    }

    // R10
    func testR10ReplacingAVoiceThatDidNotHoldThePromiseOwesNothing() {
        var claim = SharedMarginReturnClaim.none
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: true)
        XCTAssertFalse(owed)
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .none)
    }

    // R11
    func testR11AVoiceClaimIsOnlyInheritedWhileTheVoiceIsReallyPlaying() {
        var claim = SharedMarginReturnClaim.voice
        XCTAssertFalse(claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: false),
                       "a claim with no voice playing is not inherited by a later direct listen")
    }

    // R12
    func testR12TheCommonStopReleasesTheVoicesPartAndKeepsThePromptsPart() {
        var claim = SharedMarginReturnClaim.promptAndVoice
        claim.voiceStopped()
        XCTAssertEqual(claim, .prompt)

        var voiceOnly = SharedMarginReturnClaim.voice
        voiceOnly.voiceStopped()
        XCTAssertEqual(voiceOnly, .none)
    }

    // R13
    func testR13TheVoiceEndingReturnsTheSourceOnceAndThenTheClaimIsGone() {
        var claim = SharedMarginReturnClaim.voice
        XCTAssertTrue(claim.returnsSourceWhenVoiceEnds(resumeSource: true))
        claim.voiceStopped() // the common stop
        claim.voiceStopped() // the second clear after it, which changes nothing (R16)
        XCTAssertFalse(claim.returnsSourceWhenVoiceEnds(resumeSource: true), "a repeated completion cannot resume twice")
        XCTAssertEqual(claim, .none)
    }

    // R14
    func testR14TheVoiceEndingWithNothingOwedReturnsNothing() {
        let claim = SharedMarginReturnClaim.none
        XCTAssertFalse(claim.returnsSourceWhenVoiceEnds(resumeSource: true))
        XCTAssertFalse(SharedMarginReturnClaim.prompt.returnsSourceWhenVoiceEnds(resumeSource: true),
                       "the prompt's part is answered by Listen or Dismiss, not by a voice ending")
    }

    // R15
    func testR15AStopThatMustNotReturnTheSourceReturnsNothingEvenWhenOwed() {
        var claim = SharedMarginReturnClaim.voice
        XCTAssertFalse(claim.returnsSourceWhenVoiceEnds(resumeSource: false))
        claim.voiceStopped()
        XCTAssertEqual(claim, .none)
    }

    // R16
    func testR16StoppingTwiceIsTheSameAsStoppingOnce() {
        for start in [SharedMarginReturnClaim.none, .prompt, .voice, .promptAndVoice] {
            var once = start
            once.voiceStopped()
            var twice = start
            twice.voiceStopped()
            twice.voiceStopped()
            XCTAssertEqual(once, twice, "\(start)")
        }
    }

    // R18 (the nested sequence of #997's 12 Oct note, staged exactly as the model stages it)
    func testR18AListenInsideAJumpLeavesBothPartsHeldAndEachIsAnsweredOnce() {
        var claim = SharedMarginReturnClaim.none
        // 1. Prompt C is shown while the source plays: the offer paused it.
        claim.promptShown(sourceWasPlaying: true)
        XCTAssertEqual(claim, .prompt)
        // 2. The source is resumed by ordinary transport (the claim is not told). 3. A jump to Margin A
        //    captures sourceWasPlaying = true and pauses the source before it seeks.
        let jumpSawSourcePlaying = true
        // 4. The seek's snapshot assignment drains a widget Listen for C: capture, stop, start.
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: false)
        XCTAssertTrue(owed, "C's own prompt part is what owes the source back here")
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .voice)
        // 5. The outer jump finishes and shows A with the value it captured before the nested Listen.
        claim.promptShown(sourceWasPlaying: jumpSawSourcePlaying)
        XCTAssertEqual(claim, .promptAndVoice)
        // Dismissing A answers the prompt's part only; the voice keeps its own.
        XCTAssertTrue(claim.promptDismissed())
        XCTAssertEqual(claim, .voice)
        XCTAssertTrue(claim.returnsSourceWhenVoiceEnds(resumeSource: true))
    }

    // R18 (the same window from the other side: a prompt shown while Listen is between capture and restore)
    func testR18BAPromptShownBetweenCaptureAndRestoreSurvivesTheVoiceStarting() {
        var claim = SharedMarginReturnClaim.none
        let owed = claim.listenRequested(sourceIsPlaying: true, voiceIsPlaying: false)
        claim.promptShown(sourceWasPlaying: true) // a drained jump re-enters during the source's pause
        claim.voiceStopped()
        claim.voiceStarted(returnToSource: owed)
        XCTAssertEqual(claim, .promptAndVoice, "starting the voice sets only the voice's part")
    }

    // R19 (a prompt left behind by a card that was cleared without being answered)
    func testR19AStalePromptPartIsInheritedByALaterDirectListen() {
        var claim = SharedMarginReturnClaim.none
        claim.promptShown(sourceWasPlaying: true)
        // The card is cleared by opening another session; the model does not tell the claim.
        let owed = claim.listenRequested(sourceIsPlaying: false, voiceIsPlaying: false)
        XCTAssertTrue(owed, "this is today's behaviour, kept until a test says it may change")
    }

    func testANewClaimOwesNothing() {
        XCTAssertEqual(SharedMarginReturnClaim(), .none)
    }

    // The four values, as the two parts the model used to keep, so a reader can check the mapping.
    func testTheFourValuesAreTheFourCombinationsOfThePromptsAndTheVoicesPart() {
        XCTAssertEqual([SharedMarginReturnClaim.none, .prompt, .voice, .promptAndVoice].map(\.heldByPrompt),
                       [false, true, false, true])
        XCTAssertEqual([SharedMarginReturnClaim.none, .prompt, .voice, .promptAndVoice].map(\.heldByVoice),
                       [false, false, true, true])
    }
}
