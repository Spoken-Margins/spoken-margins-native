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
        XCTAssertEqual(coordinator.interruptionEnded(shouldResume: false), [.playTone(.saved)])
        XCTAssertEqual(coordinator.toneFinished(.saved), [], "iOS said not to resume")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testACallWithLessThanASecondOfSpeechDropsItForAFlag() {
        startRecording()
        feed(quiet, for: 0.5)
        feed(voice, for: 0.5)
        XCTAssertEqual(coordinator.interruptionBegan(), [.cancelRecording, .requestFlag])
        XCTAssertEqual(coordinator.interruptionEnded(shouldResume: true), [.playTone(.flag)])
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
        XCTAssertEqual(coordinator.interruptionEnded(shouldResume: true), [.resumeSource])
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

    func testFaintSpeechTheThresholdMissedIsKeptNotFlagged() {
        startRecording()
        feed(-50, for: 0.5)
        // The threshold is -42; a quiet talker at -44 never crosses it but is clearly not silence.
        XCTAssertEqual(feed(-44, for: 5.5), [.finishRecording(.silence)])
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
