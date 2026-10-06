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

    /// Review of #580: skips, seeks and rate changes send a playing item back through "starting".
    func testASkipWhilePlayingIsNotANewStart() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "podcast", status: .starting, at: tap)
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 2),
                       [.firstAudio(itemId: "podcast", milliseconds: 2_000)])

        XCTAssertEqual(watch.observe(itemId: "podcast", status: .starting, at: tap + 60), [])
        XCTAssertNil(watch.waitingItemId)
        XCTAssertFalse(watch.takeCue(at: tap + 65))
        XCTAssertEqual(watch.observe(itemId: "podcast", status: .playing, at: tap + 66), [])

        _ = watch.observe(itemId: "podcast", status: .paused, at: tap + 70)
        _ = watch.observe(itemId: "podcast", status: .starting, at: tap + 80)
        XCTAssertEqual(watch.waitingItemId, "podcast", "resuming after a pause is a start")
        XCTAssertEqual(watch.observe(itemId: "article", status: .playing, at: tap + 81),
                       [.ended(itemId: "podcast", milliseconds: 1_000, status: .playing),
                        .firstAudio(itemId: "article", milliseconds: 0)])
        _ = watch.observe(itemId: "article", status: .starting, at: tap + 90)
        XCTAssertNil(watch.waitingItemId, "a skip within the next item is not a start")
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

    /// Audit of #580: another target on the same item (a Margin's answer) is a new start; a seek on the same
    /// target is not.
    func testAnotherTargetOnTheSameItemIsANewStart() {
        var watch = PlaybackStartWatch()
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, at: tap)
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, at: tap + 5), [])
        XCTAssertNil(watch.waitingItemId, "a seek on the same target")
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, at: tap + 6)

        XCTAssertEqual(watch.observe(itemId: "article", targetId: "answer", status: .starting, at: tap + 10), [])
        XCTAssertEqual(watch.waitingTargetId, "answer")
        XCTAssertTrue(watch.takeCue(at: tap + 10.9))
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "answer", status: .playing, at: tap + 12),
                       [.firstAudio(itemId: "article", milliseconds: 2_000)])
    }

    /// Audit of #580: a new request on the same item and target (another saved session of the article) is a new
    /// start; a seek under the same request is not.
    func testANewRequestOnTheSameTargetIsANewStart() {
        var watch = PlaybackStartWatch()
        let first = tap, second = tap + 20
        _ = watch.observe(itemId: "article", targetId: "article", status: .playing, requestedAt: first, at: tap + 1)
        XCTAssertEqual(watch.observe(itemId: "article", targetId: "article", status: .starting, requestedAt: first, at: tap + 10), [])
        XCTAssertNil(watch.waitingItemId, "a seek keeps its request")
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

    func testWaitingTextNamesWhatIsHappening() {
        XCTAssertEqual(PlaybackStartWatch.waitingText(isMedia: false), "Preparing voice…")
        XCTAssertEqual(PlaybackStartWatch.waitingText(isMedia: true), "Loading audio…")
    }
}
