import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #3423: Skim stops at a Margin that will be heard, which is a recording or a reading by the iPhone's voice (the
/// owner's call: "If it's text-to-speech, then I would like Skim to control it"). `Gate1AppModel+SkimStops.swift` asks
/// `SharedMarginAudio.canOffer` for that, since #3412. A friend's Margin that will never be read aloud is a stop too (#4934, the
/// owner's call of 2026-11-22): Skim goes to its place and plays on, with no lead-in and nothing spoken. These press Skim on the real model, with a real source player and
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

    /// Every test here shares the process-wide written-Margin reader, so each one must leave it as it found it: a render
    /// left behind makes the next test's seeded reading wait behind it (the #3429 lane failure). The check is the
    /// shared fixture's, so a leak fails the test that made it.
    override func tearDown() async throws {
        await ReturnFixture.expectSharedReaderIdle()
        try await super.tearDown()
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

    /// The warnings of these words that the app put on screen, from the record every banner leaves (`feedback.shown`,
    /// #3344). The press raises its warning and the episode's resume can overwrite the status text in the same turn, so
    /// the status text is the wrong thing to watch; the record is not overwritten.
    private func warningsShown(_ model: Gate1AppModel, saying words: String) -> [String] {
        let token = DiagnosticsExport.token(words)
        return model.playbackEventRecording.events
            .filter { $0.kind == FeedbackShownEvent.shownKind && $0.fields["kind"] == "warning" && $0.fields["textToken"] == token }
            .compactMap { $0.fields["site"] }
    }

    private func bannerRecord(_ model: Gate1AppModel) -> [String] {
        model.playbackEventRecording.events.filter { $0.kind.hasPrefix("feedback.") }
            .map { "\($0.kind) \($0.fields["kind"] ?? "?") \($0.fields["site"] ?? "?")" }
    }

    private func isHeard(_ fixture: ReturnFixture) -> Bool {
        fixture.model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first?.isNewToListener == false
    }

    /// #4447: the owner's playback screen showed no Skim arrows with two of a friend's Margins ahead. Whether Skim can
    /// go forward was worked out only when the playhead or the item changed, so Margins that finished loading while
    /// the source sat paused left the arrows as they were before the Margins arrived. The chapter row must follow the
    /// Margins as they arrive, with no tick and no tap to nudge it.
    func testSkimArrowsAppearWhenAFriendsMarginsArriveWhileTheSourceIsPaused() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.sharedMarginRows = []
        model.pause()
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is paused before the Margin") {
            model.snapshot.status != .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 900
        }
        model.refreshSkimAvailabilityForTesting()
        XCTAssertFalse(model.snapshot.canSkimForward, "precondition: with no Margins loaded there is nowhere to Skim to")

        model.sharedMarginRows = [SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")]

        XCTAssertTrue(model.snapshot.canSkimForward, "the Margin that arrived is a stop ahead, so forward Skim is offered")
        XCTAssertTrue(model.showsSkimRow, "the chapter row draws its arrows")
        XCTAssertEqual(model.chapterRowForwardControl, .skim)
        // And it goes the other way when they leave (a hidden sender's, a deleted layer): no stale arrow to nowhere.
        model.sharedMarginRows = []
        XCTAssertFalse(model.snapshot.canSkimForward, "with the Margins gone there is nowhere to Skim to again")
    }

    /// #4447, the other way the Margins can arrive late: the friend's layer is on the scrubber (its rows loaded) but the
    /// item's own records for that layer are read in afterwards, as the item detail loads in the background. A layer with
    /// no records is not playable, so its Margins are no stop until they land. The arrows must follow the records, not
    /// wait for a tick that a paused source never sends.
    func testSkimArrowsAppearWhenTheItemsFriendRecordsLoadAfterTheMarginRows() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let loadedRecords = model.selectedItem.importedCommentaryInterjections
        XCTAssertFalse(loadedRecords.isEmpty, "precondition: the fixture's item carries the friend's records")
        model.pause()
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is paused before the Margin") {
            model.snapshot.status != .playing && (model.snapshot.currentMediaTimeMs ?? Int.max) < 900
        }
        // Pause and seek each start a background reload of the item, which would put the records back: let it land first.
        await model.settleItemReload()
        model.selectedItem.importedCommentaryInterjections = [:]
        model.sharedMarginRows = [SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")]
        model.refreshSkimAvailabilityForTesting()
        XCTAssertFalse(model.snapshot.canSkimForward, "precondition: the layer has no records yet, so its Margin is no stop")

        model.selectedItem.importedCommentaryInterjections = loadedRecords

        XCTAssertTrue(model.snapshot.canSkimForward, "the records arrived, so the Margin is a stop ahead and forward Skim is offered")
        XCTAssertTrue(model.showsSkimRow, "the chapter row draws its arrows")
        // And when the item's detail is replaced by one with none (a reload that lost them), the arrow goes with them.
        model.selectedItem.importedCommentaryInterjections = [:]
        XCTAssertFalse(model.snapshot.canSkimForward, "no records, no stop, no arrow to nowhere")
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
        // The warning is raised inside the press, so it is read once, right after it, with nothing to wait for.
        XCTAssertEqual(warningsShown(model, saying: "That Margin couldn't be read aloud, so listening continues.").count, 1,
                       "the listener is told the reading couldn't be read aloud; banners: \(bannerRecord(model))")
        XCTAssertEqual(warningsShown(model, saying: "That Margin's recording couldn't play, so listening continues.").count, 0,
                       "a written Margin's warning never says \"recording\"")
        XCTAssertEqual(model.diagnostics["marginMoment.voiceUnavailable"]?.hasPrefix("shared::\(fixture.layer.id)::\(fixture.record.id):"), true,
                       "\(model.diagnostics["marginMoment.voiceUnavailable"] ?? "nil")")
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

    /// Skim went to a silent Margin: no moment, no failure line, the source at the Margin's place and playing, and the card
    /// for it showing on Now (#4934).
    private func assertSkimWentSilentlyToTheMargin(_ fixture: ReturnFixture, line: UInt = #line) async throws {
        let model = fixture.model
        XCTAssertEqual(skimOutcomes(model).last, "went_to_silent_margin", "the Margin is Skim's next stop; \(skimOutcomes(model))", line: line)
        XCTAssertNil(model.marginMoment, "a silent Margin starts no moment", line: line)
        XCTAssertNil(model.lastError, "no failure line for a Margin that is a place", line: line)
        XCTAssertNotEqual(model.marginMomentConductor?.isPlayingVoice, true, "nothing is spoken", line: line)
        try await fixture.waitUntil("the source is at the Margin's place and playing") {
            (model.snapshot.currentMediaTimeMs ?? 0) >= 900 && model.snapshot.status == .playing
        }
        XCTAssertEqual(model.silentMarginLanding?.marginId, fixture.record.id, "the card is for this Margin", line: line)
        XCTAssertNotNil(model.shownSilentMarginLanding, line: line)
    }

    // A note the iPhone's voice cannot read has no recording and nothing to read: it is a silent stop, a place Skim goes to.
    func testANoteTheVoiceCannotReadIsASilentSkimStop() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await putSkimBeforeTheMargin(fixture)

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertFalse(skimOutcomes(model).contains("started_margin_lead_in"), "\(skimOutcomes(model))")
        try await assertSkimWentSilentlyToTheMargin(fixture)
    }

    // The source is paused when the press comes, as a chapter stop does today: Skim lands on the silent stop and plays on.
    func testSkimForwardFromPausedLandsOnASilentStopAndPlays() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await putSkimBeforeTheMargin(fixture)
        XCTAssertNotEqual(model.snapshot.status, .playing, "precondition: paused before the Margin")

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        try await assertSkimWentSilentlyToTheMargin(fixture)
    }

    // One press per silent stop: from the end, back lands on the Margin, and a second back press goes on past it instead of
    // meeting the stop the listener is already at (the design's `already-heard` start, #4447's position in miniature).
    func testBackTwiceFromTheEndDoesNotRepeatTheSilentStop() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: "🎧")
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.sharedMarginRows = [SharedMarginRow(interjection: fixture.record, layer: fixture.layer, itemTitle: "Real source")]
        model.pause()
        model.seekMedia(toMediaTimeMs: 25_000)
        try await fixture.waitUntil("the source is near the end") { (model.snapshot.currentMediaTimeMs ?? 0) > 24_000 }

        model.skimBackward()
        defer { model.endMarginMoment(); model.pause() }
        try await fixture.waitUntil("Skim has gone back to the Margin") { (model.snapshot.currentMediaTimeMs ?? Int.max) < 5_000 }
        XCTAssertEqual(skimOutcomes(model).last, "went_to_silent_margin")

        model.skimBackward()
        XCTAssertEqual(skimOutcomes(model).filter { $0 == "went_to_silent_margin" }.count, 1,
                       "the second press does not land on the same silent stop again: \(skimOutcomes(model))")
    }

    // MARK: The choice of whether a written Margin is read aloud (#3427)

    // Skim follows the listener's choice: with reading off it is a silent stop (a place, with nothing read), with reading on again
    // it is a voiced one with its lead-in. Both are the listener's own switch on the Margin's details, through the model, so the
    // row the screens show and the row Skim reads are the same one.
    func testSkimStopsSilentlyAtAWrittenMarginTheListenerTurnedReadingOffForAndReadsItOnceTurnedBackOn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        try await putSkimBeforeTheMargin(fixture)

        model.setSharedMarginReadAloud(fixture.record, readAloud: false)
        let muted = try XCTUnwrap(model.selectedItem.importedCommentaryInterjections[fixture.layer.id]?.first)
        XCTAssertEqual(muted.listenerReadAloud, false)
        XCTAssertFalse(SharedMarginAudio.canOffer(muted), "a Margin set not to be read aloud is not offered")
        XCTAssertEqual(model.sharedMarginRows.first?.interjection.listenerReadAloud, false, "the rows the screens read agree")
        model.skimForward()
        try await assertSkimWentSilentlyToTheMargin(fixture)
        try await fixture.waitUntil("landing is how reading turned off for a note is met: it is marked heard") { isHeard(fixture) }
        model.pause()

        model.setSharedMarginReadAloud(muted, readAloud: true)
        model.seekMedia(toMediaTimeMs: 100)
        try await fixture.waitUntil("the source is back before the Margin") { (model.snapshot.currentMediaTimeMs ?? Int.max) < 900 }
        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertEqual(skimOutcomes(model).last, "started_margin_lead_in",
                       "reading on again makes it a voiced stop, met even with the card for it still showing")
    }

    // The sender asked that it not be read aloud: Skim still stops there, with nothing read, and the Margin's words are on the card.
    func testSkimStopsSilentlyAtAWrittenMarginTheSenderAskedNotToBeReadAloud() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        let record = fixture.record
        let asked = ImportedCommentaryInterjection(
            id: record.id, layerId: record.layerId, packageScopedId: record.packageScopedId, createdAt: record.createdAt,
            anchorEvidence: record.anchorEvidence, approvedTranscript: record.approvedTranscript, audioPath: record.audioPath,
            audioDurationMs: record.audioDurationMs, podcastAnchorEvidence: record.podcastAnchorEvidence,
            resolution: record.resolution, firstHeardAt: record.firstHeardAt, replyLinks: record.replyLinks,
            alsoSharedAs: record.alsoSharedAs, shareProvenance: record.shareProvenance, senderReadAloud: false)
        try await putSkimBeforeTheMargin(fixture)
        model.sharedMarginRows = [SharedMarginRow(interjection: asked, layer: fixture.layer, itemTitle: "Real source")]
        model.selectedItem.importedCommentaryInterjections[fixture.layer.id] = [asked]

        model.skimForward()
        defer { model.endMarginMoment(); model.pause() }
        XCTAssertFalse(skimOutcomes(model).contains("started_margin_lead_in"), "\(skimOutcomes(model))")
        try await assertSkimWentSilentlyToTheMargin(fixture)
        XCTAssertEqual(model.silentMarginLanding?.words, record.approvedTranscript, "the card shows the Margin's own words")
        XCTAssertEqual(model.sharedMarginRows.first?.interjection.approvedTranscript, record.approvedTranscript,
                       "the words are still on the Margins list")
    }
}
