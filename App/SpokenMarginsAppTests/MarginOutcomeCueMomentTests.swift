import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The sound for how a spoken Margin ended (#1977): each fails when its `MarginOutcomeCuePlayer.shared.play`
/// line is removed or moved, and a written Margin, which has no recording to describe, plays nothing.
@MainActor
final class MarginOutcomeCueMomentTests: XCTestCase {
    private final class RecordingPlayer: MarginOutcomeCuePlaying {
        var played: [MarginOutcomeCue] = []
        var stops = 0
        func play(_ cue: MarginOutcomeCue) -> String { played.append(cue); return "played" }
        func stop() { stops += 1 }
    }

    private var original: MarginOutcomeCuePlaying!
    private var player: RecordingPlayer!
    private var priorTerms: [Any?] = []
    private let termsKeys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]

    override func setUp() async throws {
        original = MarginOutcomeCuePlayer.shared
        player = RecordingPlayer()
        MarginOutcomeCuePlayer.shared = player
        priorTerms = termsKeys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
    }

    override func tearDown() async throws {
        MarginOutcomeCuePlayer.shared = original
        for (key, value) in zip(termsKeys, priorTerms) {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func model() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), recordingClient: NoopRecordingClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        return model
    }

    func testFinishingARecordingPlaysExactlyOneSavedCue() {
        let model = model()
        model.beginInterjection()
        player.played.removeAll()
        model.finishInterjection()
        XCTAssertEqual(player.played.count, 1, "one ending, one sound")
        XCTAssertTrue([MarginOutcomeCue.saved, .savedMaybeCut].contains(player.played[0]))
        XCTAssertEqual(model.diagnostics["outcomeCue"], "played")
    }

    func testCancellingAndWritingPlayNoOutcomeCue() {
        let model = model()
        model.beginInterjection()
        model.cancelInterjection()
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "A thought.")
        XCTAssertEqual(player.played, [])
    }

    func testADeadMicrophoneSoundsUntilItRecoversOrTheRecordingEnds() {
        let model = model()
        model.captureHealthChanged(.notCapturing(.noAudioAfterStart), restarts: 1)
        XCTAssertEqual(player.played, [.micStopped])
        let stopsBefore = player.stops
        model.captureHealthChanged(.capturing, restarts: 1)
        XCTAssertEqual(player.stops, stopsBefore + 1, "recovery ends the cue")
        let stopsAfterRecovery = player.stops
        model.endCaptureWatch()
        XCTAssertEqual(player.stops, stopsAfterRecovery + 1, "so does the end of the recording")
    }
}
