import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #3423: Skim stops at a Margin that will be heard, which is a recording or a reading by the iPhone's voice (the
/// owner's call: "If it's text-to-speech, then I would like Skim to control it"). `Gate1AppModel+SkimStops.swift` asks
/// `SharedMarginAudio.canOffer` for that, since #3412. These press Skim on the real model, with a real source player and
/// a real file where the reading would be rendered, the way `WrittenMarginTimelineTapAppTests` does for a tap. The
/// iPhone voice itself is `WrittenMarginReadingRuntimeTests`; the sound of any of it is the owner's pass on a phone.
@MainActor
final class WrittenMarginSkimAppTests: XCTestCase {
    private static let firstUseVoiceKeys = [
        "supertonicTTSMigrationV1", "supertonicVoicePendingTermsV1", "ttsMode", "ttsVoiceSelection",
        SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey
    ]
    private var priorDefaults: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let defaults = UserDefaults.standard
        priorDefaults = [:]
        for key in Self.firstUseVoiceKeys {
            priorDefaults[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("systemImmediate", forKey: "ttsMode")
    }

    override func tearDownWithError() throws {
        let defaults = UserDefaults.standard
        for key in Self.firstUseVoiceKeys {
            if let value = priorDefaults[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try super.tearDownWithError()
    }

    private func uniqueWords() -> String { "Lovely harbour \(UUID().uuidString)" }

    /// The friend's Margin is at 1 s in the fixture's 30 s source. The source is paused and put at 0.1 s, so the press
    /// finds the Margin ahead of the playhead whatever the machine's speed, and Skim's first press plays it (the
    /// playhead is inside the lead-in).
    private func putSkimBeforeTheMargin(_ fixture: ReturnFixture) async throws {
        let model = fixture.model
        model.sharedMarginRows = [SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")]
        model.pause()
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is paused before the Margin") { (model.snapshot.currentMediaTimeMs ?? Int.max) < 900 }
    }

    private func skimOutcomes(_ model: Gate1AppModel) -> [String] {
        model.playbackEventRecording.events.filter { $0.kind == "skim.press" }.compactMap { $0.fields["outcome"] }
    }

    private func isHeard(_ fixture: ReturnFixture) -> Bool {
        fixture.model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.isNewToListener == false
    }

    // Skim forward lands on the friend's written Margin and the reading plays, as a voice Margin's recording does.
    func testSkimForwardStopsAtAFriendsWrittenMarginAndItsReadingPlays() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        try await putSkimBeforeTheMargin(fixture)

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in", "the Margin is Skim's next stop")
        XCTAssertNil(model.lastError, "no failure line for a written Margin")
        XCTAssertNotNil(model.marginMoment, "the Margin's moment started")
        try await fixture.waitUntil("the reading plays and the Margin is marked heard") { isHeard(fixture) }
        XCTAssertEqual(model.marginMomentConductor?.isPlayingVoice, true, "the reading is sounding")
        XCTAssertNil(model.lastError)
    }

    // Skim forward during the reading ends it and the episode carries on, as for a voice Margin.
    func testSkimForwardDuringAWrittenMarginsReadingEndsItAndTheEpisodeCarriesOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        try await putSkimBeforeTheMargin(fixture)
        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        try await fixture.waitUntil("the reading is sounding") { model.marginMomentConductor?.isPlayingVoice == true }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).last, "skipped_margin_voice", "the press during the reading skips it")
        try await fixture.waitUntil("the reading has ended and the episode plays again") {
            model.marginMomentConductor?.isPlayingVoice != true && model.snapshot.status == .playing
        }
        XCTAssertNil(model.lastError)
    }

    // The same press during a voice Margin's recording, so the written Margin is held to what the voice Margin does.
    func testSkimForwardDuringAVoiceMarginsRecordingEndsItAndTheEpisodeCarriesOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await putSkimBeforeTheMargin(fixture)
        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in")
        try await fixture.waitUntil("the recording is sounding") { model.marginMomentConductor?.isPlayingVoice == true }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).last, "skipped_margin_voice")
        try await fixture.waitUntil("the recording has ended and the episode plays again") {
            model.marginMomentConductor?.isPlayingVoice != true && model.snapshot.status == .playing
        }
    }

    // A reading that fails (here a file that isn't audio, as a failed or cleared render leaves) does not stop Skim
    // silently. At its turn the listener gets the warning that it couldn't be read aloud and the episode carries on;
    // the Margin stays new, and the next press goes on past it instead of meeting it again.
    func testAWrittenMarginWhoseReadingFailsUnderSkimWarnsAndSkimCanMoveOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        let reading = try XCTUnwrap(fixture.writtenReading)
        let target = WrittenMarginReader.shared.fileURL(for: reading)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not audio".utf8).write(to: target)
        _ = WrittenMarginReader.shared.start(["seed": reading])
        await WrittenMarginReader.shared.waitUntilSettled([reading], upTo: 10)
        try await putSkimBeforeTheMargin(fixture)

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in", "the Margin is still Skim's next stop")
        try await fixture.waitUntil("the listener is told the reading couldn't be read aloud") {
            model.statusMessage == "That Margin couldn't be read aloud, so listening continues."
                || model.lastError == SharedMarginAudio.unavailableWords(for: fixture.record)
        }
        XCTAssertFalse(isHeard(fixture), "a reading that never sounded does not mark the Margin heard")
        try await fixture.waitUntil("the episode plays on") { model.snapshot.status == .playing }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).filter { $0 == "started_margin_lead_in" }.count, 1, "Skim does not meet the same Margin twice")
    }

    // A voice Margin whose recording is gone is a Skim stop that cannot start. Skim says so and moves onto the stop, so
    // the next press goes on past it.
    func testAVoiceMarginWhoseRecordingIsGoneShowsTheFailureLineAndSkimMovesOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try FileManager.default.removeItem(atPath: try XCTUnwrap(fixture.record.audioPath))
        try await putSkimBeforeTheMargin(fixture)

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in")
        XCTAssertEqual(model.lastError, SharedMarginAudio.unavailableWords(for: fixture.record))
        XCTAssertEqual(model.lastError, "That Margin's recording couldn't play.")
        XCTAssertNil(model.marginMoment, "no moment starts")
        try await fixture.waitUntil("Skim has moved onto the stop") { (model.snapshot.currentMediaTimeMs ?? 0) >= 900 }

        model.skimForward()
        XCTAssertEqual(skimOutcomes(model).filter { $0 == "started_margin_lead_in" }.count, 1, "Skim does not meet the same Margin twice")
    }

    // A note the iPhone's voice cannot read has no recording and nothing to read, so it is no Skim stop at all.
    func testANoteTheVoiceCannotReadIsNoSkimStop() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await putSkimBeforeTheMargin(fixture)

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertFalse(skimOutcomes(model).contains("started_margin_lead_in"), "\(skimOutcomes(model))")
        XCTAssertNil(model.marginMoment)
    }
}
