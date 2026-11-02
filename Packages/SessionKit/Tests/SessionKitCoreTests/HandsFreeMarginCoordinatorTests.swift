import Foundation
import XCTest
@testable import SessionKit

/// Hands-free capture (#775): trigger, tone, talk, silence, tone, carry on, on a fake clock.
final class HandsFreeMarginCoordinatorTests: XCTestCase {
    /// Whole milliseconds, so window edges land exactly.
    private final class FakeClock {
        private var milliseconds = 1_000_000
        var now: TimeInterval { TimeInterval(milliseconds) / 1_000 }
        func advance(_ seconds: TimeInterval) { milliseconds += Int((seconds * 1_000).rounded()) }
    }

    private let quiet = -55.0
    private let voice = -15.0
    private var clock = FakeClock()
    private var coordinator: HandsFreeMarginCoordinator!

    override func setUp() {
        clock = FakeClock()
        let clock = self.clock
        coordinator = HandsFreeMarginCoordinator(microphonePermission: .granted, clock: { clock.now })
    }

    /// Trigger, start tone done, microphone open. Returns every command so far.
    @discardableResult
    private func startRecording() -> [HandsFreeMarginCommand] {
        var commands = coordinator.trigger(from: .headphones)
        clock.advance(0.3)
        commands += coordinator.toneFinished(.start)
        return commands
    }

    /// Feeds one level sample every 0.1 s for `seconds`.
    @discardableResult
    private func feed(_ decibels: Double, for seconds: TimeInterval) -> [HandsFreeMarginCommand] {
        var commands: [HandsFreeMarginCommand] = []
        for _ in 0..<Int((seconds * 10).rounded()) {
            clock.advance(0.1)
            commands += coordinator.level(decibels)
        }
        return commands
    }

    /// Feeds one level sample every 0.1 s, each with its own value.
    @discardableResult
    private func feed(samples decibels: [Double]) -> [HandsFreeMarginCommand] {
        var commands: [HandsFreeMarginCommand] = []
        for decibel in decibels {
            clock.advance(0.1)
            commands += coordinator.level(decibel)
        }
        return commands
    }

    /// The threshold a fresh Margin learns in a room that measures `room` dBFS, on its own clock.
    private func thresholdLearned(inARoomAt room: Double) -> Double? {
        let clock = FakeClock()
        let coordinator = HandsFreeMarginCoordinator(microphonePermission: .granted, clock: { clock.now })
        _ = coordinator.trigger(from: .headphones)
        clock.advance(0.3)
        _ = coordinator.toneFinished(.start)
        for _ in 0..<5 {
            clock.advance(0.1)
            _ = coordinator.level(room)
        }
        return coordinator.speechThresholdDB
    }

    /// Every command after the start tone is requested, up to the end of the listening window, in a room that
    /// reads `room` dBFS throughout bar one sample at `blip` (0.7 s after the microphone opens), on a fresh
    /// coordinator.
    private func commandsThroughTheListeningWindow(room: Double, oneSampleAt blip: Double) -> [HandsFreeMarginCommand] {
        let clock = FakeClock()
        let coordinator = HandsFreeMarginCoordinator(microphonePermission: .granted, clock: { clock.now })
        var commands = coordinator.trigger(from: .headphones)
        clock.advance(0.3)
        commands += coordinator.toneFinished(.start)
        for index in 0..<60 {
            clock.advance(0.1)
            commands += coordinator.level(index == 6 ? blip : room)
        }
        return Array(commands.dropFirst(2))
    }

    func testTriggerPausesPlaysTheToneThenOpensTheMicrophone() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        XCTAssertEqual(coordinator.phase, .startTone)
        XCTAssertEqual(coordinator.triggerSource, .headphones)
        XCTAssertEqual(coordinator.toneFinished(.start), [.beginRecording])
        XCTAssertEqual(coordinator.phase, .listening)
    }

    func testSilenceForTheListeningWindowMakesAFlagAndCarriesOn() {
        startRecording()
        XCTAssertEqual(feed(quiet, for: 5.9), [])
        XCTAssertEqual(feed(quiet, for: 0.1), [.cancelRecording, .requestFlag, .playTone(.flag)])
        XCTAssertEqual(coordinator.phase, .rejoining)
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testTheListeningWindowAlsoEndsOnATickWithoutSamples() {
        startRecording()
        clock.advance(6)
        XCTAssertEqual(coordinator.tick(), [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testSpeechThenTwoAndAHalfSecondsOfQuietSavesThenPlaysTheSaveTone() {
        startRecording()
        feed(quiet, for: 0.5)
        XCTAssertEqual(feed(voice, for: 3), [])
        XCTAssertEqual(coordinator.phase, .speaking)
        XCTAssertEqual(feed(quiet, for: 2.4), [])
        XCTAssertEqual(coordinator.phase, .trailingSilence)
        XCTAssertEqual(feed(quiet, for: 0.1), [.finishRecording(.silence)])
        XCTAssertEqual(coordinator.phase, .saving)
        // The save tone means "it's safe", so it waits for the save.
        XCTAssertEqual(coordinator.tick(), [])
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAShortPauseMidSentenceDoesNotEndTheMargin() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 1)
        feed(quiet, for: 2)
        XCTAssertEqual(feed(voice, for: 1), [])
        XCTAssertEqual(coordinator.phase, .speaking)
    }

    func testAPressFinishesAtOnce() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
    }

    func testAPressBeforeAnySpeechMakesAFlag() {
        startRecording()
        feed(quiet, for: 1)
        XCTAssertEqual(coordinator.trigger(from: .lockScreen), [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testTheCapWarnsAtFourThirtyAndSavesAtFive() {
        startRecording()
        feed(quiet, for: 0.5)
        XCTAssertFalse(feed(voice, for: 269.4).contains(.playTone(.capWarning)))
        XCTAssertEqual(feed(voice, for: 0.1), [.playTone(.capWarning)])
        XCTAssertEqual(feed(voice, for: 29.9).filter { $0 == .playTone(.capWarning) }, [], "warns once")
        XCTAssertEqual(feed(voice, for: 0.1), [.finishRecording(.cap)])
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
    }

    func testASecondTriggerWithinHalfASecondIsABounce() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        clock.advance(0.4)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [])
        XCTAssertEqual(coordinator.phase, .startTone)

        startRecordingAfterBounce()
        feed(quiet, for: 0.5)
        feed(voice, for: 1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)], "a later press still finishes")
    }

    private func startRecordingAfterBounce() {
        clock.advance(0.2)
        XCTAssertEqual(coordinator.toneFinished(.start), [.beginRecording])
    }

    func testACallAfterASecondOfSpeechKeepsTheMarginCutShort() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 1.5)
        XCTAssertEqual(coordinator.interruptionBegan(), [.finishRecording(.interruption)])
        XCTAssertTrue(HandsFreeFinishReason.interruption.isCutShort)
        // Saved during the call: the tone waits for the call to end.
        XCTAssertEqual(coordinator.saveCompleted(), [])
        XCTAssertEqual(coordinator.interruptionEnded(.audioStaysStopped), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [], "iOS said not to resume")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testACallWithLessThanASecondOfSpeechDropsItForAFlag() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 0.5)
        XCTAssertEqual(coordinator.interruptionBegan(), [.cancelRecording, .requestFlag])
        XCTAssertEqual(coordinator.interruptionEnded(.audioMayStart), [.playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
    }

    func testRemovedHeadphonesSaveAndLeaveTheSourcePaused() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.headphonesRemoved(), [.finishRecording(.headphonesRemoved)])
        XCTAssertEqual(coordinator.saveCompleted(), [], "no tone from the phone speaker, no resume")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testRemovedHeadphonesBeforeSpeechFlagAndStayPaused() {
        startRecording()
        XCTAssertEqual(coordinator.headphonesRemoved(), [.cancelRecording, .requestFlag])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testWithoutMicrophonePermissionATriggerGivesAFlag() {
        coordinator.microphonePermission = .denied
        XCTAssertEqual(coordinator.trigger(from: .siri), [.pauseSource, .requestFlag, .playTone(.couldNotRecord)])
        XCTAssertEqual(coordinator.toneFinished(.couldNotRecord), [.resumeSource])
        coordinator.microphonePermission = .undetermined
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .lockScreen), [.pauseSource, .requestFlag, .playTone(.couldNotRecord)])
    }

    func testANoisyBackgroundRaisesTheThreshold() {
        // A quiet room: the threshold sits low.
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 1)
        XCTAssertEqual(coordinator.speechThresholdDB, -47)
        coordinator.trigger(from: .onScreen)
        _ = coordinator.saveCompleted()
        _ = coordinator.toneFinished(.saved)

        // A car at -35 dB: learned from the first half-second, so the road noise reads as quiet
        // and the Margin still ends 2.5 s after the listener stops talking.
        clock.advance(1)
        startRecording()
        let road = -35.0
        feed(road, for: 0.5)
        XCTAssertEqual(coordinator.phase, .listening)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.speechThresholdDB, -27)
        XCTAssertEqual(feed(road, for: 2.5), [.finishRecording(.silence)])
    }

    /// The room is measured over the first half-second: four samples, 0.1 s to 0.4 s, and the threshold
    /// is learned when the fifth arrives. Every other test feeds one repeated level, so first, last,
    /// loudest, quietest and mean were the same number. A cough, a click or a breath in that half-second
    /// must not raise the line speech has to cross.
    func testTheBackgroundIsTheQuietestSampleOfTheFirstHalfSecond() {
        startRecording()
        // First -40, quietest -55 (second), loudest -30, last -45, mean -42.5: each rule gives a different answer.
        feed(samples: [-40, -55, -30, -45])
        XCTAssertNil(coordinator.speechThresholdDB, "still measuring the room")
        feed(samples: [-60])
        XCTAssertEqual(coordinator.speechThresholdDB, -47, "the quietest sample plus the 8 dB speech margin")
        XCTAssertEqual(coordinator.phase, .listening)

        // The learned line is the one that counts: -48 is under it, -46 is speech.
        feed(samples: [-48])
        XCTAssertEqual(coordinator.phase, .listening)
        feed(samples: [-46])
        XCTAssertEqual(coordinator.phase, .speaking)
    }

    /// Speech has to rise 8 dB over the room, but the line stays between -50 and -25 dBFS: a very quiet
    /// room must not put it where the microphone's own hiss crosses it, and a loud one must not put it
    /// out of reach of a normal voice. The edges are literals so a changed constant fails here.
    func testTheLearnedThresholdStaysBetweenMinus50AndMinus25() {
        XCTAssertEqual(thresholdLearned(inARoomAt: -80), -50, "a silent room is held at the lowest line")
        XCTAssertEqual(thresholdLearned(inARoomAt: -58), -50, "the room that lands exactly on the lowest line")
        XCTAssertEqual(thresholdLearned(inARoomAt: -57), -49, "just inside the range is not moved")
        XCTAssertEqual(thresholdLearned(inARoomAt: -34), -26, "just inside the range is not moved")
        XCTAssertEqual(thresholdLearned(inARoomAt: -33), -25, "the room that lands exactly on the highest line")
        XCTAssertEqual(thresholdLearned(inARoomAt: -10), -25, "a loud room is held at the highest line")
    }

    func testAStartToneThatNeverReportsFinishingOpensTheMicrophone() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        clock.advance(2.9)
        XCTAssertEqual(coordinator.tick(), [])
        XCTAssertEqual(coordinator.phase, .startTone)
        clock.advance(0.1)
        XCTAssertEqual(coordinator.tick(), [.beginRecording])
        XCTAssertEqual(coordinator.phase, .listening)
        // The Margin carries on as if the tone had finished: it records, then the source resumes.
        feed(quiet, for: 0.5)
        feed(voice, for: 1)
        XCTAssertEqual(feed(quiet, for: 2.5), [.finishRecording(.silence)])
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAStartToneThatNeverReportsFinishingAndNoSpeechStillResumesTheSource() {
        coordinator.trigger(from: .headphones)
        clock.advance(60)
        XCTAssertEqual(coordinator.tick(), [.beginRecording])
        XCTAssertEqual(feed(quiet, for: 6), [.cancelRecording, .requestFlag, .playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testTheStartToneReportingFinishingAfterTheTimeoutDoesNotOpenTheMicrophoneTwice() {
        coordinator.trigger(from: .headphones)
        clock.advance(3)
        XCTAssertEqual(coordinator.tick(), [.beginRecording])
        clock.advance(0.5)
        XCTAssertEqual(coordinator.toneFinished(.start), [])
        XCTAssertEqual(coordinator.phase, .listening)
        // With no tick in between, the late report itself opens the microphone, once.
        coordinator.abandon()
        clock.advance(1)
        coordinator.trigger(from: .headphones)
        clock.advance(10)
        XCTAssertEqual(coordinator.toneFinished(.start), [.beginRecording])
        XCTAssertEqual(coordinator.toneFinished(.start), [])
        XCTAssertEqual(coordinator.phase, .listening)
    }

    func testAPressAfterTheStartToneTimedOutFlagsTheSpotAndLeavesNothingOpen() {
        coordinator.trigger(from: .headphones)
        clock.advance(3.5)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.beginRecording, .cancelRecording, .requestFlag, .playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testSpeechFromTheFirstSampleThenQuietIsKeptNotFlagged() {
        // #1031: the first half-second is all speech at -30, so it first reads as the room.
        // Half a second of quiet after it shows what the room really is, the words already spoken
        // then count, and the Margin ends 2.5 s after the last of them (3 s + 2.5 s = 5.5 s).
        startRecording()
        XCTAssertEqual(feed(-30, for: 3), [])
        XCTAssertEqual(feed(quiet, for: 2.4), [])
        XCTAssertEqual(coordinator.phase, .trailingSilence)
        XCTAssertEqual(coordinator.speechThresholdDB, -47, "re-learned from the quiet")
        XCTAssertEqual(feed(quiet, for: 0.1), [.finishRecording(.silence)])
        XCTAssertEqual(coordinator.speechSeconds, 3, accuracy: 0.001, "the first half-second counts too")
    }

    func testSpeechFromTheFirstSampleWithPausesIsRecordedToItsEnd() {
        // Talking at -30 from the first sample, with a pause between sentences. The pause shows
        // the room, so the rest counts as speech and the Margin isn't cut at the window.
        startRecording()
        XCTAssertEqual(feed(-30, for: 2), [])
        XCTAssertEqual(feed(-50, for: 0.6), [])
        XCTAssertEqual(feed(-30, for: 8), [], "past the six-second window, still speaking")
        XCTAssertEqual(coordinator.phase, .speaking)
        XCTAssertEqual(feed(quiet, for: 2.5), [.finishRecording(.silence)])
    }

    func testACallKeepsSpeechRecoveredFromTheInitialCalibration() {
        // The interrupted-save rule needs a second of speech. Words misread as calibration
        // must contribute to that duration after the quiet pause reveals the room.
        startRecording()
        XCTAssertEqual(feed(-30, for: 1.2), [])
        XCTAssertEqual(feed(quiet, for: 0.6), [])
        XCTAssertEqual(coordinator.phase, .trailingSilence)
        XCTAssertEqual(coordinator.speechSeconds, 1.2, accuracy: 0.001)
        XCTAssertEqual(coordinator.interruptionBegan(), [.finishRecording(.interruption)])
        XCTAssertEqual(coordinator.saveCompleted(), [], "the save tone waits for the call to end")
        XCTAssertEqual(coordinator.interruptionEnded(.audioMayStart), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [.resumeSource])

        // A new silent capture must not inherit the recovered words or the quieter run.
        clock.advance(1)
        startRecording()
        XCTAssertEqual(coordinator.speechSeconds, 0)
        XCTAssertNil(coordinator.speechThresholdDB)
        XCTAssertEqual(feed(quiet, for: 6), [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testLoudSpeechFromTheFirstSampleIsKept() {
        // Control: -20 clears the top clamp (-25) even when the first samples read as the room.
        startRecording()
        feed(-20, for: 3)
        XCTAssertEqual(coordinator.phase, .speaking)
        XCTAssertEqual(feed(quiet, for: 2.5), [.finishRecording(.silence)])
    }

    func testOneQuietSampleBeforeTheSpeechSetsTheRoom() {
        // Control: one quiet sample among the first four puts the threshold at -47.
        startRecording()
        feed(quiet, for: 0.1)
        feed(-30, for: 3)
        XCTAssertEqual(coordinator.speechThresholdDB, -47)
        XCTAssertEqual(coordinator.phase, .speaking)
        XCTAssertEqual(feed(quiet, for: 2.5), [.finishRecording(.silence)])
    }

    func testTheThresholdOnlyRelearnsBeforeSpeechStarts() {
        // A dip during the Margin must not drag the threshold under the road noise.
        startRecording()
        feed(-35, for: 0.5)
        feed(voice, for: 1)
        XCTAssertEqual(coordinator.speechThresholdDB, -27)
        feed(-50, for: 0.1)
        XCTAssertEqual(coordinator.speechThresholdDB, -27)
        XCTAssertEqual(feed(-35, for: 2.5), [.finishRecording(.silence)])
    }

    func testSteadyNoiseWithAQuietBlipOrShortDipStillMakesAFlag() {
        // A silent listener in a car at -35: one quiet sample, a glitch, or a dip under half a
        // second must not teach the threshold a quieter room, or the noise would read as speech.
        for (name, dip, seconds) in [("one quiet sample", -60.0, 0.1), ("a glitch", -160.0, 0.1), ("a 0.4 s dip", -60.0, 0.4)] {
            coordinator.abandon()
            clock.advance(1)
            startRecording()
            feed(-35, for: 2)
            feed(dip, for: seconds)
            let commands = feed(-35, for: 4)
            XCTAssertEqual(commands, [.cancelRecording, .requestFlag, .playTone(.flag)], name)
            XCTAssertEqual(coordinator.speechThresholdDB, -27, name)
        }
    }

    func testAQuietRoomThatDriftsOrClicksStillMakesAFlag() {
        // Drift of a few dB and a click in the first sample are not speech, and don't teach the room.
        startRecording()
        feed(quiet, for: 0.4)
        feed(quiet + 3, for: 2.1)
        XCTAssertEqual(feed(quiet - 2, for: 3.5), [.cancelRecording, .requestFlag, .playTone(.flag)], "drift")

        coordinator.abandon()
        clock.advance(1)
        startRecording()
        feed(quiet + 25, for: 0.1)
        feed(quiet, for: 0.3)
        XCTAssertEqual(feed(quiet - 1, for: 5.6), [.cancelRecording, .requestFlag, .playTone(.flag)], "click")
    }

    func testAQuietRoomWithMeteringJitterStillMakesAFlag() {
        // A fixed jitter of about 3 dB around -55, longer than the listening window.
        let jitter: [Double] = [0, 1.5, -1, 2, -1.5, 0.5, 2.5, -0.5, 1, -2, 3, 0, -1, 2, 0.5, -1.5, 1.5, 0, 2, -0.5]
        startRecording()
        var commands: [HandsFreeMarginCommand] = []
        for step in 0..<60 {
            clock.advance(0.1)
            commands += coordinator.level(quiet + jitter[step % jitter.count])
        }
        XCTAssertEqual(commands, [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testAQuietRoomThatWobblesAFewDecibelsStillMakesAFlag() {
        startRecording()
        var commands: [HandsFreeMarginCommand] = []
        for step in 0..<60 {
            clock.advance(0.1)
            commands += coordinator.level(quiet + Double(step % 4) - 1)
        }
        XCTAssertEqual(commands, [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testEventsOutsideAMarginDoNothing() {
        XCTAssertEqual(coordinator.level(voice), [])
        XCTAssertEqual(coordinator.tick(), [])
        XCTAssertEqual(coordinator.saveCompleted(), [])
        XCTAssertEqual(coordinator.toneFinished(.saved), [])
        XCTAssertEqual(coordinator.interruptionBegan(), [])
        XCTAssertEqual(coordinator.headphonesRemoved(), [])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAFailedSaveFlagsTheSpotWithTheLowTone() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.saveFailed(), [.requestFlag, .playTone(.couldNotRecord)])
        XCTAssertEqual(coordinator.toneFinished(.couldNotRecord), [.resumeSource])
    }

    func testAPressAfterACallWithNoEndNoticeClosesTheMargin() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        coordinator.interruptionBegan()
        XCTAssertEqual(coordinator.saveCompleted(), [])
        clock.advance(120)
        // iOS never said the call ended. The next press plays the save tone and leaves the
        // source paused, since nothing said to resume.
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [])
        XCTAssertEqual(coordinator.phase, .idle)
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)], "ready for the next one")
    }

    func testACallThatCutsTheClosingToneOffResumesOnlyWhenItEnds() {
        startRecording()
        feed(quiet, for: 6)
        XCTAssertEqual(coordinator.phase, .rejoining)
        XCTAssertEqual(coordinator.interruptionBegan(), [])
        XCTAssertEqual(coordinator.interruptionEnded(.audioMayStart), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testAClosingToneThatNeverReportsFinishingTimesOut() {
        startRecording()
        feed(quiet, for: 6)
        XCTAssertEqual(coordinator.phase, .rejoining)
        clock.advance(2.9)
        XCTAssertEqual(coordinator.tick(), [])
        clock.advance(0.1)
        XCTAssertEqual(coordinator.tick(), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// A press has already started the save when the headphones come out: no save tone from the phone
    /// speaker and no resume. (Pulling them out while talking is `testRemovedHeadphonesSaveAnd...`.)
    func testHeadphonesPulledWhileASaveIsInFlightStillLeaveTheSourcePausedWithNoTone() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.headphonesRemoved(), [])
        XCTAssertEqual(coordinator.saveCompleted(), [], "no save tone and no resume from the phone speaker")
        XCTAssertEqual(coordinator.phase, .idle)
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)], "ready for the next one")
    }

    /// The save tone is already playing when the headphones come out: nothing resumes the source.
    func testHeadphonesPulledDuringTheClosingToneDoNotResumeTheSource() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
        XCTAssertEqual(coordinator.phase, .rejoining)
        XCTAssertEqual(coordinator.headphonesRemoved(), [])
        XCTAssertEqual(coordinator.phase, .idle, "nothing is left to wait for")
        XCTAssertEqual(coordinator.toneFinished(.saved), [], "the headphones are out, so the source stays paused")
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)], "ready for the next one")
    }

    /// The call begins after the save was already requested: the save tone, and the resume after it,
    /// wait for the call to end, whichever of the save and the call ends first.
    func testACallThatBeginsWhileASaveIsInFlightHoldsTheSaveToneUntilItEnds() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.interruptionBegan(), [])
        XCTAssertEqual(coordinator.saveCompleted(), [], "the save tone would play into the call")
        XCTAssertEqual(coordinator.interruptionEnded(.audioMayStart), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testACallThatEndsBeforeTheSaveFinishesStillWaitsForTheSave() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.interruptionBegan(), [])
        XCTAssertEqual(coordinator.interruptionEnded(.audioStaysStopped), [], "the Margin is not stored yet")
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [], "iOS said not to resume")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: A press while only faint words have been heard (#1030)

    /// The room reads -50 dBFS, so the threshold is -42. Faint words at -44 never cross it but are 6 dB over
    /// the room, which the attempt rule keeps. Leaves the coordinator still `.listening`, 3 s in.
    private func recordFaintWords() {
        startRecording()
        feed(-50, for: 0.5)
        feed(-44, for: 2.5)
        XCTAssertEqual(coordinator.phase, .listening)
    }

    func testAPressAfterFaintWordsKeepsThemInsteadOfFlagging() {
        recordFaintWords()
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        XCTAssertEqual(coordinator.phase, .saving)
        XCTAssertEqual(coordinator.saveCompleted(), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testEveryTriggerSourceKeepsFaintWordsOnAPress() {
        for source in [HandsFreeTriggerSource.headphones, .carPlay, .lockScreen, .actionButton, .siri, .watch, .onScreen] {
            setUp()
            recordFaintWords()
            XCTAssertEqual(coordinator.trigger(from: source), [.finishRecording(.press)], "\(source)")
        }
    }

    func testRemotePressAtThreeSecondsUsesTheSameAttemptBoundaryAsTheSilenceTimeout() {
        // Room: -50; speech threshold: -42. Exactly 4 dB over the room is still a flag;
        // just above it is kept, even at the speech threshold (which speech must exceed).
        let cases: [(level: Double, keepsWords: Bool)] = [
            (-50, false), (-46.1, false), (-46, false),
            (-45.9, true), (-44, true), (-42, true)
        ]
        for source in [HandsFreeTriggerSource.headphones, .carPlay, .lockScreen] {
            for sample in cases {
                for endByPress in [true, false] {
                    let clock = FakeClock()
                    let capture = HandsFreeMarginCoordinator(microphonePermission: .granted, clock: { clock.now })
                    XCTAssertEqual(capture.trigger(from: source), [.pauseSource, .playTone(.start)])
                    XCTAssertEqual(capture.toneFinished(.start), [.beginRecording])
                    for index in 0..<30 {
                        clock.advance(0.1)
                        XCTAssertEqual(capture.level(index < 5 ? -50 : sample.level), [])
                    }
                    let context = "\(source), \(sample.level) dBFS, \(endByPress ? "press" : "timeout")"
                    XCTAssertEqual(capture.speechThresholdDB, -42, context)
                    XCTAssertEqual(capture.phase, .listening, context)
                    XCTAssertEqual(capture.speechSeconds, 0, context)

                    let commands: [HandsFreeMarginCommand]
                    if endByPress {
                        commands = capture.trigger(from: source)
                    } else {
                        clock.advance(3)
                        commands = capture.tick()
                    }
                    if sample.keepsWords {
                        XCTAssertEqual(commands, [.finishRecording(endByPress ? .press : .silence)], context)
                        XCTAssertEqual(capture.phase, .saving, context)
                        XCTAssertEqual(capture.tick(), [], "save tone must wait for storage: \(context)")
                        XCTAssertEqual(capture.saveCompleted(), [.playTone(.saved)], context)
                        XCTAssertEqual(capture.toneFinished(.saved), [.resumeSource], context)
                    } else {
                        XCTAssertEqual(commands, [.cancelRecording, .requestFlag, .playTone(.flag)], context)
                        XCTAssertEqual(capture.toneFinished(.flag), [.resumeSource], context)
                    }
                    XCTAssertEqual(capture.phase, .idle, context)
                }
            }
        }
    }

    func testAPressWithNothingSaidIsStillAFlag() {
        startRecording()
        feed(quiet, for: 3)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.cancelRecording, .requestFlag, .playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
    }

    func testAPressAfterOnlyMicrophoneJitterIsStillAFlag() {
        startRecording()
        feed(quiet, for: 1)
        feed(samples: [-54])
        feed(quiet, for: 1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.cancelRecording, .requestFlag, .playTone(.flag)])
    }

    func testASecondPressInsideTheBounceWindowAfterFaintWordsIsOneCommand() {
        recordFaintWords()
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.finishRecording(.press)])
        clock.advance(0.2)
        XCTAssertEqual(coordinator.trigger(from: .lockScreen), [])
        XCTAssertEqual(coordinator.phase, .saving)
    }

    func testRemovedHeadphonesAfterFaintWordsSaveThemAndStayPaused() {
        recordFaintWords()
        XCTAssertEqual(coordinator.headphonesRemoved(), [.finishRecording(.headphonesRemoved)])
        XCTAssertEqual(coordinator.saveCompleted(), [], "no tone from the phone speaker, no resume")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// An interruption keeps a Margin only with a second of speech heard (the coordinator's own comment),
    /// so faint words below the threshold are still a flag. Pinned so a change to it is deliberate.
    func testAnInterruptionAfterOnlyFaintWordsIsStillAFlag() {
        recordFaintWords()
        XCTAssertEqual(coordinator.interruptionBegan(), [.cancelRecording, .requestFlag])
    }

    func testFaintSpeechTheThresholdMissedIsKeptNotFlagged() {
        startRecording()
        feed(-50, for: 0.5)
        // The threshold is -42; a quiet talker at -44 never crosses it but is clearly not silence.
        XCTAssertEqual(feed(-44, for: 5.5), [.finishRecording(.silence)])
    }

    /// A single blip also follows the attempt rule: a few dB of microphone jitter stays a flag,
    /// and a sample just over the margin is kept. The remote-press table pins exactly 4.0 dB.
    func testAQuietRoomWithAFewDecibelsOfJitterStillEndsAsAFlag() {
        for blip in [-54.0, -52.0] {
            XCTAssertEqual(
                commandsThroughTheListeningWindow(room: quiet, oneSampleAt: blip),
                [.beginRecording, .cancelRecording, .requestFlag, .playTone(.flag)],
                "one sample \(blip - quiet) dB over a room at \(quiet) dBFS is jitter, not an attempt to talk"
            )
        }
    }

    func testASampleMoreThanFourDecibelsOverTheRoomIsKeptNotFlagged() {
        for blip in [-50.5, -45.0] {
            XCTAssertEqual(
                commandsThroughTheListeningWindow(room: quiet, oneSampleAt: blip),
                [.beginRecording, .finishRecording(.silence)],
                "one sample \(blip - quiet) dB over a room at \(quiet) dBFS is words the threshold missed"
            )
        }
    }

    /// A second press before the microphone opened: nothing to keep, so a flag, and the source resumes.
    func testASecondPressBeforeTheMicrophoneOpensMakesAFlagAndResumesTheSource() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        clock.advance(0.6)
        XCTAssertEqual(coordinator.trigger(from: .lockScreen), [.requestFlag, .playTone(.flag)])
        XCTAssertEqual(coordinator.phase, .rejoining)
        XCTAssertEqual(coordinator.toneFinished(.start), [], "the start tone ending late must not open the microphone")
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// The start tone was playing in the headphones when they came out: the phone microphone must not
    /// open once it ends, and the source stays paused.
    func testHeadphonesPulledDuringTheStartToneFlagAndNeverOpenTheMicrophone() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        XCTAssertEqual(coordinator.headphonesRemoved(), [.requestFlag])
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.toneFinished(.start), [], "no recording through the phone microphone")
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)], "ready for the next one")
    }

    /// A call arrives while the start tone plays: a flag keeps the spot, the microphone stays closed, and
    /// the tone and the resume wait for the call to end.
    func testACallDuringTheStartToneFlagsTheSpotAndResumesOnlyWhenItEnds() {
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        XCTAssertEqual(coordinator.interruptionBegan(), [.requestFlag])
        XCTAssertEqual(coordinator.toneFinished(.start), [], "the microphone stays closed during the call")
        XCTAssertEqual(coordinator.phase, .saving)
        XCTAssertEqual(coordinator.interruptionEnded(.audioMayStart), [.playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [.resumeSource])
        XCTAssertEqual(coordinator.phase, .idle)

        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
        XCTAssertEqual(coordinator.interruptionBegan(), [.requestFlag])
        XCTAssertEqual(coordinator.interruptionEnded(.audioStaysStopped), [.playTone(.flag)])
        XCTAssertEqual(coordinator.toneFinished(.flag), [], "iOS said not to resume")
    }

    func testAbandonReturnsToIdle() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 2)
        coordinator.trigger(from: .headphones)
        coordinator.abandon()
        XCTAssertEqual(coordinator.phase, .idle)
        clock.advance(1)
        XCTAssertEqual(coordinator.trigger(from: .headphones), [.pauseSource, .playTone(.start)])
    }
}
