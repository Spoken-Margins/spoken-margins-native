import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The moments a listener feels a tap for (#1978): each fails when its `AppHaptics.play` line is removed or
/// moved, and the discard of an empty recording is one tap, not two.
@MainActor
final class HapticsMomentTests: XCTestCase {
    private final class RecordingSink: HapticFeedbackSink {
        var played: [HapticKind] = []
        func play(_ kind: HapticKind) { played.append(kind) }
    }

    private var original: HapticFeedbackSink!
    private var sink: RecordingSink!
    private var priorTerms: [Any?] = []
    private let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]

    /// The Terms must be accepted before the model is made, or nothing plays and nothing can be recorded over.
    override func setUp() async throws {
        original = AppHaptics.sink
        sink = RecordingSink()
        AppHaptics.sink = sink
        priorTerms = termsKeys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        AppHaptics.sink = original
        for (key, value) in zip(termsKeys, priorTerms) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func model(audio: AudioPlaybackClient = NoopAudioPlaybackClient()) -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: audio, recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        return model
    }

    func testStartingAMarginTapsOnceAndCancellingEndsSoftly() {
        let model = model()
        sink.played.removeAll()
        model.beginInterjection()
        XCTAssertTrue(model.snapshot.isRecording)
        XCTAssertEqual(sink.played, [.started])
        model.cancelInterjection()
        XCTAssertEqual(sink.played, [.started, .ended])
    }

    func testFinishingARecordingEndsWithExactlyOneSavedOrWarningTap() {
        let model = model()
        model.beginInterjection()
        sink.played.removeAll()
        model.finishInterjection()
        XCTAssertFalse(model.snapshot.isRecording)
        XCTAssertEqual(sink.played.count, 1, "one outcome, one tap")
        XCTAssertTrue([HapticKind.saved, .warning].contains(sink.played[0]), "kept, with or without a caveat")
    }

    func testASavedWrittenMarginTapsSaved() {
        let model = model()
        model.beginWrittenMargin()
        sink.played.removeAll()
        model.saveWrittenMargin(text: "A thought.")
        XCTAssertEqual(sink.played, [.saved])
    }

    func testTheSleepTimerEndingTapsOnce() throws {
        let model = model()
        model.armSleepTimer(.minutes15)
        defer { model.cancelSleepTimer() }
        guard case .armed(_, let deadline?, _) = model.sleepTimerState else { return XCTFail("Expected armed sleep timer") }
        sink.played.removeAll()
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(-1))
        XCTAssertEqual(sink.played, [], "nothing before the deadline")
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(sink.played, [.ended])
        model.reconcileSleepTimer(now: deadline.addingTimeInterval(2))
        XCTAssertEqual(sink.played, [.ended], "the timer is gone, so it cannot tap again")
    }
}
