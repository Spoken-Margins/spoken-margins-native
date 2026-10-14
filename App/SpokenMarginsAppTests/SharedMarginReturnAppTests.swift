import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// Who owes the source back after a shared Margin (#997). These tests drive the real model with a
/// real source player and a real shared Margin voice, and say what the listener gets: the source
/// comes back, or it does not. They pass on the two stored booleans this slice removes and must pass
/// unchanged on `SharedMarginReturnClaim`. Row ids are those of the "Shared Margin return claim"
/// table in `docs/gate1-playback-transition-table.md`.
@MainActor
final class SharedMarginReturnAppTests: XCTestCase {
    // The AudioAdapters plan runs with the app's data removed, so the first-use voice choice is still
    // pending and startItem() would wait on the terms sheet (#599). Same setup as MediaPlaybackInterruptionTests.
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

    // R01, R03: the offer paused the playing source, so dismissing it brings the source back.
    func testDismissingAPromptThatPausedThePlayingSourceResumesIt() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))
        XCTAssertNotNil(model.pendingImportedCommentary)
        XCTAssertEqual(model.snapshot.status, .paused, "the offer paused the source")

        model.dismissPendingImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
        XCTAssertNil(model.pendingImportedCommentary)
    }

    // R02, R04: the source was already paused when the offer arrived, so dismissing leaves it paused.
    func testDismissingAPromptOverAnAlreadyPausedSourceLeavesItPaused() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.pause()
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))
        XCTAssertNotNil(model.pendingImportedCommentary)

        model.dismissPendingImportedCommentary()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.snapshot.status, .paused, "nothing paused it for the offer, so nothing owes it back")
    }

    // R07, R13: Listen on the offer keeps the promise, and Return keeps it exactly once.
    func testListeningToAnOfferThatPausedTheSourceBringsItBackOnceOnReturn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))

        model.listenToPendingImportedCommentary()
        XCTAssertNotNil(model.playingImportedCommentary)
        XCTAssertEqual(model.snapshot.status, .paused)

        model.returnToSourceFromImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
        model.pause()
        model.returnToSourceFromImportedCommentary()
        XCTAssertEqual(model.snapshot.status, .paused, "a second return cannot resume it again")
    }

    // R06: Listen from the Timeline while the source plays pauses it and owes it back.
    func testListeningWhileTheSourcePlaysBringsItBackOnReturn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.returnToSourceFromImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
    }

    // R08: Listen over a source the listener had paused owes nothing.
    func testListeningOverAPausedSourceWithNoOfferLeavesItPausedOnReturn() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.pause()

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        model.returnToSourceFromImportedCommentary()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.snapshot.status, .paused)
    }

    // R09: Retry replaces a failed voice, and the promise made for the first attempt carries to the second.
    func testRetryingAFailedVoiceKeepsThePromiseToBringTheSourceBack() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true, voiceIsReadable: false)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        try await fixture.waitUntil("the failure shows") { model.importedCommentaryPhase.isFailed }
        model.retryImportedCommentary()
        try await fixture.waitUntil("the retry fails too") { model.importedCommentaryPhase.isFailed }
        XCTAssertEqual(model.snapshot.status, .paused)

        model.returnToSourceFromImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
    }

    // R19: today's behaviour, kept until a test says it may change. Opening another session clears the
    // card without answering the offer (G1 startNewSession, openSession, resumeSession set
    // `pendingImportedCommentary = nil`), so the offer's promise survives and a later direct Listen over the
    // paused source inherits it.
    func testAnOfferClearedWithoutAnswerStillOwesTheSourceToALaterListen() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))
        XCTAssertEqual(model.snapshot.status, .paused)
        model.pendingImportedCommentary = nil // what the session-opening paths do

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        model.returnToSourceFromImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
    }

    // R12, R15: stopping the voice by any route but Return owes nothing afterwards.
    func testStoppingTheVoiceDropsThePromiseToBringTheSourceBack() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        model.stopInterjectionAudioPlayback()
        model.returnToSourceFromImportedCommentary()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.snapshot.status, .paused)
    }

    // R12: stopping the voice keeps the offer's promise (the card's own answer is still owed).
    func testStoppingTheVoiceKeepsTheOffersPromise() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        XCTAssertTrue(model.jumpToImportedCommentary(interjectionID: fixture.record.id))
        model.stopInterjectionAudioPlayback()
        XCTAssertNotNil(model.pendingImportedCommentary)

        model.dismissPendingImportedCommentary()
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
    }

    // #1538 (owner's call): your own Margin, played from its detail, ends and the source plays again by itself,
    // then the item's later spoken Margins follow as playback reaches them.
    func testAnOwnMarginThatPausedTheSourceBringsItBackAndLaterMarginsFollow() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let heard = try fixture.addOwnMargin(id: "own-heard", atMediaTimeMs: 100, voiceSeconds: 1)
        let later = try fixture.addOwnMargin(id: "own-later", atMediaTimeMs: 4_500, voiceSeconds: 1)
        _ = try fixture.addOwnMargin(id: "own-earlier", atMediaTimeMs: 0, voiceSeconds: 1)
        // The fixture's shared Margin sits at 1 s and would pause the source for its own offer when playback crosses
        // it after the resume. Start past it, so the only Margin ahead is the later one.
        model.seekMedia(toMediaTimeMs: 1_500)
        try await fixture.waitUntil("the source is past the shared Margin") { (model.snapshot.currentMediaTimeMs ?? 0) >= 1_400 }
        XCTAssertEqual(model.snapshot.status, .playing)

        model.toggleInterjectionAudioPlayback(heard)
        XCTAssertEqual(model.snapshot.status, .paused, "playing your Margin from its detail pauses the source")
        XCTAssertTrue(model.isPlayingInterjectionAudio(heard))

        try await fixture.waitUntil("the Margin ends", timeout: 10) { !model.isPlayingInterjectionAudio(heard) }
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
        let moment = try XCTUnwrap(model.marginMoment, "the later Margin is waiting for playback to reach it")
        XCTAssertEqual(moment.phase, .listening)
        XCTAssertEqual(moment.unplayed.map(\.marginId), [Gate1AppModel.marginIdentity(later)],
                       "the Margin just heard and the one before the resume point never play again")

        try await fixture.waitUntil("playback reaches the later Margin and it plays", timeout: 10) { model.marginMoment?.isPlayingMargin == true }
        try await fixture.waitUntil("the source carries on after it", timeout: 10) {
            model.snapshot.status == .playing && model.marginMoment == nil
        }
    }

    // #1538: moving from one of your Margins to another while the first plays keeps the promise to bring the source back.
    func testSwitchingFromOneOwnMarginToAnotherStillBringsTheSourceBackWhenTheSecondEnds() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let first = try fixture.addOwnMargin(id: "own-first", atMediaTimeMs: 100, voiceSeconds: 5)
        let second = try fixture.addOwnMargin(id: "own-second", atMediaTimeMs: 150, voiceSeconds: 1)

        model.toggleInterjectionAudioPlayback(first)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.toggleInterjectionAudioPlayback(second)
        XCTAssertFalse(model.isPlayingInterjectionAudio(first))
        XCTAssertTrue(model.isPlayingInterjectionAudio(second))

        try await fixture.waitUntil("the second Margin ends", timeout: 10) { !model.isPlayingInterjectionAudio(second) }
        try await fixture.waitUntil("the source plays again") { model.snapshot.status == .playing }
    }

    // #1538: the listener had paused the source themselves, so a Margin that ends owes it nothing.
    func testAnOwnMarginPlayedOverAPausedSourceLeavesItPausedWhenItEnds() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let heard = try fixture.addOwnMargin(id: "own-heard", atMediaTimeMs: 100, voiceSeconds: 1)
        model.pause()
        XCTAssertEqual(model.snapshot.status, .paused)

        model.toggleInterjectionAudioPlayback(heard)
        try await fixture.waitUntil("the Margin ends", timeout: 10) { !model.isPlayingInterjectionAudio(heard) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertNil(model.marginMoment)
    }

    // #1538: stopping your Margin yourself is not it ending, so the source stays where the listener left it.
    func testStoppingAnOwnMarginYourselfLeavesTheSourcePaused() async throws {
        let fixture = try await ReturnFixture.make(sourcePlaying: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        let heard = try fixture.addOwnMargin(id: "own-heard", atMediaTimeMs: 100, voiceSeconds: 5)

        model.toggleInterjectionAudioPlayback(heard)
        XCTAssertEqual(model.snapshot.status, .paused)
        model.toggleInterjectionAudioPlayback(heard)
        XCTAssertFalse(model.isPlayingInterjectionAudio(heard))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertNil(model.marginMoment)
    }

    // #1538: an article has no media clock for later Margins to wait on, so the source resumes and nothing more starts.
    func testAnOwnMarginOnAnArticleBringsTheSourceBackWithoutAMarginMoment() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-return-article-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        defer { model.stopInterjectionAudioPlayback(); model.pause() }
        model.startItem(id: "item-pill")
        let sessionID = try XCTUnwrap(model.snapshot.sessionId, "terms gate: \(model.diagnostics["termsGate"] ?? "none"), \(model.statusMessage)")
        XCTAssertEqual(model.snapshot.status, .playing)
        let voice = root.appending(path: "own.wav")
        try FileManager.default.moveItem(at: try ReturnFixture.makeWAV(duration: 1), to: voice)
        let own = Interjection(
            id: "own-article", itemId: "item-pill", sessionId: sessionID,
            targetType: .item, targetId: "item-pill", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .text, startChar: 10, endChar: 20, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: voice.path, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try SQLiteSessionStore(path: db.path).saveInterjection(own)

        model.toggleInterjectionAudioPlayback(own)
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertTrue(model.isPlayingInterjectionAudio(own))
        let deadline = Date().addingTimeInterval(10)
        while model.isPlayingInterjectionAudio(own), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isPlayingInterjectionAudio(own), "the Margin reached its end")
        XCTAssertEqual(model.snapshot.status, .playing, "the article is playing again by itself")
        XCTAssertNil(model.marginMoment)
    }
}

@MainActor
private struct ReturnFixture {
    let model: Gate1AppModel
    let layer: ImportedCommentaryLayer
    let record: ImportedCommentaryInterjection
    private let root: URL
    private let files: [URL]

    static func make(sourcePlaying: Bool, voiceIsReadable: Bool = true) async throws -> ReturnFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = try makeWAV(duration: 30)
        let voiceURL = try makeWAV(duration: 30)
        if !voiceIsReadable { try Data("not audio".utf8).write(to: voiceURL) }
        let db = root.appending(path: "library.sqlite")
        let sourcePlayer = AVPlayerStreamPlaybackClient()
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: sourcePlayer)
        let model = Gate1AppModel(audioPlaybackClient: routed, databaseURLOverride: db)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let itemID = "real-source"
        try store.seed(item: Item(id: itemID, title: "Real source", mediaType: "audiobook", text: nil,
            externalReference: sourceURL.absoluteString, status: "ready", externalReferenceType: "audiobook",
            media: ItemMedia(sourceType: .nativeMediaFile, url: sourceURL.absoluteString, durationMs: 30_000, nativeMediaId: "source-audio")))
        model.startItem(id: itemID)
        if sourcePlaying {
            for _ in 0..<150 where (sourcePlayer.currentMediaTimeMs() ?? 0) < 200 { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThan(sourcePlayer.currentMediaTimeMs() ?? 0, 100, "the source is playing before the test starts")
        }
        let layer = ImportedCommentaryLayer(id: "received", itemId: itemID, packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .other, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: true, revealMode: .companion)
        let record = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Reviewed words", audioPath: voiceURL.path, audioDurationMs: 30_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        // In the store, not only on the model: pause, seek and every transport call refresh the selected item
        // from the store, which would otherwise empty its Margins and make Listen and jump find nothing.
        _ = try store.importCommentaryLayer(layer, interjections: [record])
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]
        return ReturnFixture(model: model, layer: layer, record: record, root: root, files: [sourceURL, voiceURL])
    }

    /// One of your own spoken Margins on the source's current session, with a short voice and its place in the source.
    func addOwnMargin(id: String, atMediaTimeMs mediaTimeMs: Int, voiceSeconds: TimeInterval) throws -> Interjection {
        let voice = root.appending(path: "\(id).wav")
        try FileManager.default.moveItem(at: try Self.makeWAV(duration: voiceSeconds), to: voice)
        let own = Interjection(
            id: id, itemId: "real-source", sessionId: try XCTUnwrap(model.snapshot.sessionId),
            targetType: .item, targetId: "real-source", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
            audioPath: voice.path, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
        try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path).saveInterjection(own)
        return own
    }

    func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func cleanUp() {
        model.stopInterjectionAudioPlayback()
        model.pendingImportedCommentary = nil
        model.pause()
        for url in files + [root] { try? FileManager.default.removeItem(at: url) }
    }

    fileprivate static func makeWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-return-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
