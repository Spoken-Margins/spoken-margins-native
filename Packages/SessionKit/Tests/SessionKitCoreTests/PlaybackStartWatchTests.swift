import Foundation
import XCTest
import SessionKit

/// #357: a start that stays silent gets a cue, and each start's time to first audio is recorded.
final class PlaybackStartWatchTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 1_000)

    func testRecordsTimeFromStartToFirstAudio() {
        var watch = PlaybackStartWatch()

        XCTAssertEqual(watch.observe(itemId: "article", status: .starting, at: tap), [])
        XCTAssertEqual(watch.observe(itemId: "article", status: .starting, at: tap + 5), [])
        XCTAssertEqual(watch.waitingItemId, "article")
        let outcome = watch.observe(itemId: "article", status: .playing, at: tap + 14.6)

        XCTAssertEqual(outcome, [.firstAudio(itemId: "article", milliseconds: 14_600)])
        XCTAssertNil(watch.waitingItemId)
        XCTAssertEqual(watch.observe(itemId: "article", status: .playing, at: tap + 20), [], "only the first audio counts")
    }

    func testASeekThatBecomesSilentHasItsOwnWaitingCueClock() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", status: .playing, requestedAt: tap, at: tap + 1)
        _ = watch.observe(itemId: "article", status: .starting, requestedAt: tap, at: tap + 60)

        XCTAssertEqual(watch.waitingItemId, "article")
        XCTAssertEqual(watch.cueWait(at: tap + 60) ?? -1, 0.8, accuracy: 0.001,
                       "the old playback request is not the beginning of this seek's wait")
        XCTAssertFalse(watch.takeCue(at: tap + 60.5))
        XCTAssertTrue(watch.takeCue(at: tap + 60.81))
        XCTAssertEqual(watch.observe(itemId: "article", status: .playing, requestedAt: tap, at: tap + 62),
                       [.firstAudio(itemId: "article", milliseconds: 2_000)])
    }

    func testAnInstantOrQuickSeekDoesNotProduceAWaitingCue() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", status: .playing, requestedAt: tap, at: tap)
        _ = watch.observe(itemId: "article", status: .playing, requestedAt: tap, at: tap + 60)
        XCTAssertNil(watch.waitingItemId, "cached audio can keep playing without a silent start")
        _ = watch.observe(itemId: "article", status: .starting, requestedAt: tap, at: tap + 70)
        _ = watch.observe(itemId: "article", status: .playing, requestedAt: tap, at: tap + 70.2)
        XCTAssertFalse(watch.takeCue(at: tap + 71), "a quick pending seek resolves before its cue")
    }

    func testAStartThatEndsWithoutAudioIsNotCountedAsFirstAudio() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", status: .starting, at: tap)

        XCTAssertEqual(watch.observe(itemId: "article", status: .paused, at: tap + 3),
                       [.ended(itemId: "article", milliseconds: 3_000, status: .paused)])

        _ = watch.observe(itemId: "article", status: .starting, at: tap + 10)
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .starting, at: tap + 11),
                       [.ended(itemId: "article", milliseconds: 1_000, status: .starting)])
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 12.25),
                       [.firstAudio(itemId: "podcast", milliseconds: 1_250)])
    }

    /// #1101: skips and seeks may need fresh audio. Their wait is timed from the silent transition.
    func testAPendingSkipWhilePlayingGetsACueWithoutReusingItsOriginalStartTime() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "podcast", status: .starting, at: tap)
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 2),
                       [.firstAudio(itemId: "podcast", milliseconds: 2_000)])

        XCTAssertEqual(watch.observe(itemId: "podcast", status: .starting, at: tap + 60), [])
        XCTAssertEqual(watch.waitingItemId, "podcast")
        XCTAssertTrue(watch.takeCue(at: tap + 65))
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 66),
                       [.firstAudio(itemId: "podcast", milliseconds: 6_000)])

        _ = watch.observe(itemId: "podcast", status: .paused, at: tap + 70)
        _ = watch.observe(itemId: "podcast", status: .starting, at: tap + 80)
        XCTAssertEqual(watch.waitingItemId, "podcast", "resuming after a pause is a start")
        XCTAssertEqual(watch.observe(itemId: "article", status: .playing, at: tap + 81),
                       [.ended(itemId: "podcast", milliseconds: 1_000, status: .playing),
                        .firstAudio(itemId: "article", milliseconds: 0)])
        _ = watch.observe(itemId: "article", status: .starting, at: tap + 90)
        XCTAssertEqual(watch.waitingItemId, "article", "a pending skip within the next item can be silent too")
    }

    /// Audit of #580: a buffered resume can go straight from paused to playing, and still counts as a start.
    func testAStartConfirmedAtOnceIsRecordedAsFirstAudio() {
        var watch = PlaybackStartWatch()
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap),
                       [.firstAudio(itemId: "podcast", milliseconds: 0)])
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 1), [])
        _ = watch.observe(itemId: "podcast", status: .paused, at: tap + 30)
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 40),
                       [.firstAudio(itemId: "podcast", milliseconds: 0)])
        XCTAssertNil(watch.waitingItemId)
        XCTAssertFalse(watch.takeCue(at: tap + 45), "no cue for a start that already has audio")
    }

    func testCueComesOnceAfterTheDelayAndNotForAQuickStart() {
        var watch = PlaybackStartWatch(cueDelay: 0.8)
        _ = watch.observe(itemId: "quick", status: .starting, at: tap)
        XCTAssertFalse(watch.takeCue(at: tap + 0.5))
        _ = watch.observe(itemId: "quick", status: .playing, at: tap + 0.6)
        XCTAssertFalse(watch.takeCue(at: tap + 0.9), "audio already started")

        _ = watch.observe(itemId: "slow", status: .starting, at: tap + 10)
        XCTAssertFalse(watch.takeCue(at: tap + 10.7))
        XCTAssertTrue(watch.takeCue(at: tap + 10.81))
        XCTAssertFalse(watch.takeCue(at: tap + 12), "one cue per start")
        XCTAssertFalse(watch.takeCue(at: tap + 20))
    }

    /// Audit of #580: the cue is due 0.8 s after the request, so work before the start was published counts.
    func testCueWaitRunsFromTheRequest() {
        var watch = PlaybackStartWatch(cueDelay: 0.8)
        XCTAssertNil(watch.cueWait(at: tap), "no open start")
        _ = watch.observe(itemId: "article", status: .starting, requestedAt: tap, at: tap + 0.3)
        XCTAssertEqual(watch.cueWait(at: tap + 0.3) ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(watch.cueWait(at: tap + 2), 0, "overdue: check at once")
        XCTAssertTrue(watch.takeCue(at: tap + 0.81))

        _ = watch.observe(itemId: "podcast", status: .starting, at: tap + 10)
        XCTAssertEqual(watch.cueWait(at: tap + 10) ?? -1, 0.8, accuracy: 0.001, "no request stamp: the full delay")
    }

    /// Another target on the same item (a Margin's answer) is a new start; a pending seek also opens a wait.
    func testAnotherTargetOnTheSameItemIsANewStart() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, at: tap)
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, at: tap + 5), [])
        XCTAssertEqual(watch.waitingItemId, "article", "a silent seek on the same target")
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, at: tap + 6)

        XCTAssertEqual(watch.observe(itemId: "article", targetId: "answer", status: .starting, at: tap + 10), [])
        XCTAssertEqual(watch.waitingTargetId, "answer")
        XCTAssertTrue(watch.takeCue(at: tap + 10.9))
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "answer", status: .playing, at: tap + 12),
                       [.firstAudio(itemId: "article", milliseconds: 2_000)])
    }

    /// A new request on the same item and target uses its request time; a pending seek uses its transition time.
    func testANewRequestOnTheSameTargetIsANewStart() {
        var watch = PlaybackStartWatch()
        let first = tap, second = tap + 20
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, requestedAt: first, at: tap + 1)
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, requestedAt: first, at: tap + 10), [])
        XCTAssertEqual(watch.waitingItemId, "article", "a seek keeps its request but still needs a waiting cue")
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, requestedAt: first, at: tap + 11)
        let opened = watch.startCount

        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, requestedAt: second, at: second + 0.2), [])
        XCTAssertEqual(watch.waitingItemId, "article")
        XCTAssertEqual(watch.startCount, opened + 1)
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .playing, requestedAt: second, at: second + 4),
                       [.firstAudio(itemId: "article", milliseconds: 4_000)])
    }

    /// Audit of #580: when prepared narration times out and the engine switches the waiting start to live speech,
    /// it is still the same request: one cue, and the time runs from the tap.
    func testATargetSwitchUnderTheSameRequestKeepsTheStart() {
        var watch = PlaybackStartWatch(cueDelay: 0.8)
        _ = watch.observe(itemId: "article", targetId: "narration.m4a", status: .starting, requestedAt: tap, at: tap + 0.1)
        let opened = watch.startCount
        XCTAssertTrue(watch.takeCue(at: tap + 0.9))

        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, requestedAt: tap, at: tap + 10), [])
        XCTAssertEqual(watch.startCount, opened, "the same start")
        XCTAssertFalse(watch.takeCue(at: tap + 11), "one cue per tap")
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .playing, requestedAt: tap, at: tap + 12),
                       [.firstAudio(itemId: "article", milliseconds: 12_000)])
    }

    func testChimeIsAShortValidWave() throws {
        let data = PlaybackStartChime.wavData()
        let header = String(decoding: data.prefix(4), as: UTF8.self) + String(decoding: data[8..<16], as: UTF8.self)
        XCTAssertEqual(header, "RIFFWAVEfmt ")
        let seconds = Double(data.count - 44) / 2 / Double(PlaybackStartChime.sampleRate)
        XCTAssertEqual(seconds, 0.21, accuracy: 0.01)
        let samples = stride(from: 44, to: data.count, by: 2).map { Int16(littleEndian: Int16(data[$0]) | Int16(data[$0 + 1]) << 8) }
        let loudest = Double(samples.map { abs(Int($0)) }.max() ?? 0) / Double(Int16.max)
        XCTAssertEqual(loudest, PlaybackStartChime.peak, accuracy: 0.01, "soft, never full scale")
        XCTAssertLessThan(abs(Int(samples.first ?? 1)), 200, "fades in, no click")
    }

    /// #357 follow-up: the waiting sound is one whole period (pops, then silence) so the audio player can loop it.
    func testWaitingCueIsOnePeriodOfSoftPopsThenSilence() throws {
        let data = PlaybackWaitingCue.wavData()
        let header = String(decoding: data.prefix(4), as: UTF8.self) + String(decoding: data[8..<16], as: UTF8.self)
        XCTAssertEqual(header, "RIFFWAVEfmt ")
        let seconds = Double(data.count - 44) / 2 / Double(PlaybackWaitingCue.sampleRate)
        XCTAssertEqual(seconds, PlaybackWaitingCue.period, accuracy: 0.001, "a loop that repeats on the period")
        let samples = stride(from: 44, to: data.count, by: 2).map { Int16(littleEndian: Int16(data[$0]) | Int16(data[$0 + 1]) << 8) }
        let rate = Double(PlaybackWaitingCue.sampleRate)
        let loudest = Double(samples.map { abs(Int($0)) }.max() ?? 0) / Double(Int16.max)
        XCTAssertGreaterThan(loudest, 0.05, "audible")
        XCTAssertLessThan(loudest, PlaybackWaitingCue.peak + 0.01, "quieter than the start chime")
        XCTAssertLessThan(PlaybackWaitingCue.peak, PlaybackStartChime.peak)
        XCTAssertEqual(samples.first, 0, "starts at zero, no click")
        XCTAssertEqual(samples.last, 0, "ends at zero, no click when it loops")
        let lastPop = PlaybackWaitingCue.pops.map(\.start).max() ?? 0
        let quietFrom = Int((lastPop + PlaybackWaitingCue.popSeconds + 0.01) * rate)
        XCTAssertEqual(samples[quietFrom...].map { abs(Int($0)) }.max(), 0, "silence after the pops")
        for pop in PlaybackWaitingCue.pops {
            let from = Int(pop.start * rate), to = Int((pop.start + PlaybackWaitingCue.popSeconds) * rate)
            XCTAssertGreaterThan(samples[from..<to].map { abs(Int($0)) }.max() ?? 0, 1_000, "a pop at \(pop.start) s")
        }
    }

    /// The waiting sound comes about two seconds after the start chime, which itself comes at 0.8 s.
    func testWaitingCueTimingConstants() {
        XCTAssertEqual(PlaybackWaitingCue.delay, 2.0)
        XCTAssertGreaterThan(PlaybackWaitingCue.period, PlaybackStartChime.notes.map(\.seconds).reduce(0, +))
        XCTAssertGreaterThan(PlaybackWaitingCue.limit, PlaybackWaitingCue.delay + PlaybackWaitingCue.period)
    }

    func testWaitingTextNamesWhatIsHappening() {
        XCTAssertEqual(PlaybackStartWatch.waitingText(isMedia: false), "Preparing voice…")
        XCTAssertEqual(PlaybackStartWatch.waitingText(isMedia: true), "Loading audio…")
    }

    // MARK: First sound reported by the audio client (#842)

    /// A client reports its first sound, so the start's cue is not wanted even though the engine still says "starting".
    func testFirstSoundBeforeTheCueDelayMeansNoCue() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap)

        XCTAssertTrue(watch.firstAudioHeard(targetId: "article-target"))
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap + 0.6)
        XCTAssertFalse(watch.takeCue(at: tap + 0.9), "sound began at 0.5 s, so the 0.8 s chime would play over it")
        XCTAssertFalse(watch.takeCue(at: tap + 5))
        XCTAssertEqual(watch.waitingItemId, "article", "the signal closes nothing; the engine's .playing does")
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article-target", status: .playing, at: tap + 1.1),
                       [.firstAudio(itemId: "article", milliseconds: 1_100)], "firstAudioMs keeps its meaning")
    }

    func testASignalForAnotherTargetChangesNothing() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap)

        XCTAssertFalse(watch.firstAudioHeard(targetId: "an-earlier-target"))
        XCTAssertTrue(watch.takeCue(at: tap + 0.81), "a late signal from the old start must not silence this one's cue")
    }

    func testASignalWithNoOpenStartReturnsFalse() {
        var watch = PlaybackStartWatch()
        XCTAssertFalse(watch.firstAudioHeard(targetId: "article-target"))

        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap)
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .playing, at: tap + 1)
        XCTAssertFalse(watch.firstAudioHeard(targetId: "article-target"), "the start already resolved")
        XCTAssertNil(watch.waitingItemId)
    }

    /// The engine fell back to another voice after the first sound: that target has not been heard, so it gets its cue.
    func testAHeardStartThatMovesToAnotherTargetGetsItsCueAgain() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "narration", status: .starting, requestedAt: tap, at: tap)
        XCTAssertTrue(watch.firstAudioHeard(targetId: "narration"))

        // Same listener request (same `requestedAt`), so the engine's fallback keeps the wait on another target.
        _ = watch.observe(itemId: "article", targetId: "live-speech", status: .starting, requestedAt: tap, at: tap + 0.5)

        XCTAssertEqual(watch.waitingItemId, "article")
        XCTAssertEqual(watch.waitingTargetId, "live-speech")
        XCTAssertTrue(watch.takeCue(at: tap + 0.9))
    }

    func testAHeardStartThatKeepsItsTargetStaysHeard() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "narration", status: .starting, at: tap)
        XCTAssertTrue(watch.firstAudioHeard(targetId: "narration"))

        _ = watch.observe(itemId: "article", targetId: "narration", status: .starting, at: tap + 0.5)

        XCTAssertFalse(watch.takeCue(at: tap + 0.9))
    }

    func testAStartWithNoTargetCannotBeHeard() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", status: .starting, at: tap)

        XCTAssertFalse(watch.firstAudioHeard(targetId: "article-target"))
        XCTAssertTrue(watch.takeCue(at: tap + 0.81))
    }

    /// A new start for the same item opens clean: the old start's heard mark does not carry over.
    func testANewStartAfterAHeardOneIsNotMarkedHeard() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap)
        XCTAssertTrue(watch.firstAudioHeard(targetId: "article-target"))
        _ = watch.observe(itemId: "article", targetId: "article-target", status: .paused, at: tap + 2)

        _ = watch.observe(itemId: "article", targetId: "article-target", status: .starting, at: tap + 10)

        XCTAssertTrue(watch.takeCue(at: tap + 10.9))
    }
}
