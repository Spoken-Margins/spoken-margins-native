import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #3365: a tap on a friend's written Margin takes the voice path, with its reading as the audio. These tests drive the
/// real model, a real source player and a real file where the reading would be rendered; the iPhone voice itself is
/// `WrittenMarginReadingRuntimeTests`. Each reading's words are its own, so one test's file is never another's.
@MainActor
final class WrittenMarginTapAppTests: XCTestCase {
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

    // A reading that is ready plays at once, as a voice Margin does: the source pauses, the card says the iPhone's voice
    // is reading the friend's words (never "speaking"), and the episode comes back when it ends.
    func testATapOnAWrittenMarginWhoseReadingIsReadyPlaysItLikeAVoiceAndBringsTheEpisodeBack() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))

        model.listenToPendingImportedCommentary()
        XCTAssertNotNil(model.playingImportedCommentary, "it plays at once, with no wait")
        XCTAssertEqual(model.snapshot.status, .paused, "the episode waits for the reading")
        // The card says "loading" until the voice's first health check (about 0.2 s); then it says whose words are read.
        try await fixture.waitUntil("the card says the iPhone's voice is reading") { model.pinnedMarginCard?.stage == .reading }
        XCTAssertTrue(model.pinnedMarginCard?.detail.contains("Your phone's voice is reading Reviewer's words.") == true, "\(String(describing: model.pinnedMarginCard?.detail))")

        model.returnToSourceFromImportedCommentary()
        try await fixture.waitUntil("the episode plays again after the reading") { model.snapshot.status == .playing }
    }

    // A friend's Margin on a podcast that hasn't been placed yet has only the sender's time. Listening needs no place
    // in the listener's copy: the reading plays and nothing is reported as failed.
    func testAWrittenMarginOnAnUnplacedLayerPlaysWithoutALocalTime() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords(), unplaced: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: true)

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertNil(model.lastError, "no failure line: the sender's time is enough to listen")
    }

    // The reading is not ready on the tap: it waits (with the existing line), then plays from the same path once it is.
    func testATapBeforeTheReadingIsReadyWaitsThenPlays() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: false) // on disk, not yet looked at: the reader still has to find it
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))

        model.listenToPendingImportedCommentary()
        XCTAssertNil(model.playingImportedCommentary, "nothing plays before the reading is ready")
        try await fixture.waitUntil("the reading plays once it is ready") { model.playingImportedCommentary != nil }
        try await fixture.waitUntil("the card says the iPhone's voice is reading") { model.pinnedMarginCard?.stage == .reading }
    }

    // A tone-only card expires after a few seconds. Tapping Listen on a reading that isn't ready must stop that expiry,
    // or the card runs out during the wait and the listener gets silence with no line.
    func testTappingListenOnAReadingNotReadyStopsTheCardsExpiry() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: false)
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))
        let expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            model.dismissPendingImportedCommentary()
        }
        model.importedCommentaryAutoPlayTask = expiry
        defer { expiry.cancel() }

        model.listenToPendingImportedCommentary()
        XCTAssertTrue(expiry.isCancelled, "the card's expiry no longer runs once Listen is tapped")
        XCTAssertNil(model.importedCommentaryAutoPlayTask)
    }

    // "Hear only the Margins" holds for readings that aren't ready, but only while the listener does nothing else:
    // anything they do (here, pausing the episode) means the review never starts from the hold.
    func testAReviewHoldEndsWhenTheListenerDoesSomethingElse() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: false)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        XCTAssertNil(model.marginMoment, "the review waits for its readings")
        model.pause()
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertNil(model.marginMoment, "the listener moved on, so the review does not start by itself")
    }

    // The same hold, left alone, starts the review once the reading is ready.
    func testAReviewHoldStartsTheReviewWhenNothingElseHappens() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: false)

        model.reviewNewMargins(itemId: "real-source", thenContinue: true)
        try await fixture.waitUntil("the review starts", timeout: 10) { model.marginMoment != nil }
    }

    // Dismissing the card ends the wait: when the reading arrives, nothing plays.
    func testAWaitIsAbandonedWhenThePromptIsDismissed() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, writtenWords: uniqueWords())
        defer { fixture.cleanUp() }
        let model = fixture.model
        try await fixture.seedReading(ready: false)
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))

        model.listenToPendingImportedCommentary()
        model.dismissPendingImportedCommentary()
        let reading = try XCTUnwrap(fixture.writtenReading)
        try await fixture.waitUntil("the reading is ready, with nobody waiting for it") { WrittenMarginReader.shared.isReady(reading) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(model.playingImportedCommentary, "a dismissed card plays nothing when its reading arrives")
        XCTAssertNil(model.marginMoment)
        XCTAssertNil(model.pendingImportedCommentary)
    }
}
