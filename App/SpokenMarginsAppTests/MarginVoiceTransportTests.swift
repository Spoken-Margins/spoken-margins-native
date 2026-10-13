import AVFoundation
import Combine
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// The Margin voice transport as the model shows it (#993). These tests use only the model's own API and a
/// real `AVPlayer` on real WAV files, so they pass on the code before the voice player moved out of
/// `Gate1AppModel` and must pass unchanged after. They pin what the extraction could silently change:
/// when observers are told, when a poll ends a voice, and which audio-session options each route sets.
@MainActor
final class MarginVoiceTransportTests: XCTestCase {
    /// Observers are told a change is coming before it lands, as `@Published` did, for every change the
    /// transport makes: the voice starting, pausing, resuming and stopping.
    func testEveryVoiceStateChangeIsAnnouncedBeforeItHappens() throws {
        let fixture = try VoiceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        var playingAtEachNotice: [Bool] = []
        var pausedAtEachNotice: [Bool] = []
        let observation = model.objectWillChange.sink {
            playingAtEachNotice.append(model.playingImportedCommentary != nil)
            pausedAtEachNotice.append(model.importedCommentaryIsPaused)
        }
        defer { observation.cancel() }

        model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
        XCTAssertNotNil(model.playingImportedCommentary)
        XCTAssertFalse(playingAtEachNotice.isEmpty, "starting the voice told the observers")
        XCTAssertEqual(playingAtEachNotice.first, false, "the first notice came before the voice was published")
        XCTAssertTrue(playingAtEachNotice.contains(true), "later changes of the voice's state were announced too")

        pausedAtEachNotice.removeAll()
        model.setImportedCommentaryPaused(true)
        XCTAssertTrue(model.importedCommentaryIsPaused)
        XCTAssertEqual(pausedAtEachNotice.first, false, "pausing was announced before it happened")

        pausedAtEachNotice.removeAll()
        model.setImportedCommentaryPaused(false)
        XCTAssertFalse(model.importedCommentaryIsPaused)
        XCTAssertEqual(pausedAtEachNotice.first, true, "resuming was announced before it happened")

        playingAtEachNotice.removeAll()
        model.stopInterjectionAudioPlayback()
        XCTAssertNil(model.playingImportedCommentary)
        XCTAssertEqual(playingAtEachNotice.first, true, "stopping was announced before the voice was cleared")
    }

    /// A shared Margin's voice is published before its card is cleared: clearing the card rebuilds the
    /// compact controls' state, which stands down while a shared Margin plays.
    func testTheSharedMarginVoiceIsPublishedBeforeItsCardIsCleared() throws {
        let fixture = try VoiceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let prompt = ImportedCommentaryPrompt(layer: fixture.layer, interjection: fixture.record, index: 1, count: 1)
        model.pendingImportedCommentary = prompt
        var voicePublishedWhenCardClears: [Bool] = []
        let observation = model.$pendingImportedCommentary.sink { newValue in
            if newValue == nil { voicePublishedWhenCardClears.append(model.playingImportedCommentary != nil) }
        }
        defer { observation.cancel() }

        model.listenToPendingImportedCommentary()

        XCTAssertEqual(voicePublishedWhenCardClears, [true])
        XCTAssertEqual(model.playingImportedCommentary?.id, fixture.record.id)
    }

    /// Your own Margin whose file cannot be decoded stops itself and says so (the poll's failure rule).
    func testAnOwnMarginWhoseFileCannotBePlayedStopsAndSaysSo() throws {
        let fixture = try VoiceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let own = try fixture.ownMargin(unreadable: true)

        model.toggleInterjectionAudioPlayback(own)
        XCTAssertTrue(model.isPlayingInterjectionAudio(own), "asking to play shows it playing until the player says otherwise")

        try waitUntil("the failure stops it") { !model.isPlayingInterjectionAudio(own) }
        XCTAssertEqual(model.lastError, "This Margin's audio couldn't be played.")
        XCTAssertNil(model.playingInterjectionAudioId)
        XCTAssertEqual(model.playingInterjectionAudioRate, 1)
    }

    /// Your own Margin that plays to its end stops itself and clears what it published.
    func testAnOwnMarginThatPlaysToItsEndStopsItself() throws {
        let fixture = try VoiceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let own = try fixture.ownMargin(unreadable: false)

        model.toggleInterjectionAudioPlayback(own)
        XCTAssertTrue(model.isPlayingInterjectionAudio(own))
        XCTAssertEqual(model.playingInterjectionAudioId, own.id)
        XCTAssertEqual(model.playingInterjectionAudioSessionID, own.sessionId)

        try waitUntil("it reaches its end and stops", timeout: 10) { !model.isPlayingInterjectionAudio(own) }
        XCTAssertNil(model.playingInterjectionAudioId)
        XCTAssertNil(model.playingInterjectionAudioSessionID)
        XCTAssertEqual(model.playingInterjectionAudioRate, 1)
        XCTAssertNil(model.lastError, "reaching the end is not a failure")
    }

    /// Your own Margin lowers other audio, whatever the listener's mixing settings are.
    func testAnOwnMarginPlaysWithTheDuckingSessionOptions() throws {
        let fixture = try VoiceFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.mixesWithOtherAudio = true
        model.lowersBackgroundAudio = false
        let own = try fixture.ownMargin(unreadable: false)

        model.toggleInterjectionAudioPlayback(own)
        defer { model.stopInterjectionAudioPlayback() }

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .spokenAudio)
        // Not asserted: .mixWithOthers. iOS reports it alongside .duckOthers, so it says nothing about the route.
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers))
    }

    /// A shared Margin's session follows the listener's mixing settings, in all four combinations.
    func testASharedMarginPlaysWithTheSessionOptionsThatMatchTheMixingSettings() throws {
        for (mixes, lowers) in [(false, false), (false, true), (true, false), (true, true)] {
            let fixture = try VoiceFixture()
            defer { fixture.cleanUp() }
            let model = fixture.model
            model.mixesWithOtherAudio = mixes
            model.lowersBackgroundAudio = lowers

            model.listenToImportedCommentary(layerID: fixture.layer.id, interjectionID: fixture.record.id)
            XCTAssertNotNil(model.playingImportedCommentary, "mixes \(mixes), lowers \(lowers)")

            let session = AVAudioSession.sharedInstance()
            XCTAssertEqual(session.category, .playback, "mixes \(mixes), lowers \(lowers)")
            XCTAssertEqual(session.mode, .spokenAudio, "mixes \(mixes), lowers \(lowers)")
            XCTAssertEqual(session.categoryOptions.contains(.mixWithOthers), mixes, "mixes \(mixes), lowers \(lowers)")
            XCTAssertEqual(session.categoryOptions.contains(.duckOthers), mixes && lowers, "mixes \(mixes), lowers \(lowers)")
            model.stopInterjectionAudioPlayback()
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// A seeded item with one shared Margin whose voice is a real WAV file, and a way to make your own Margin.
@MainActor
private final class VoiceFixture {
    let model: Gate1AppModel
    let layer: ImportedCommentaryLayer
    let record: ImportedCommentaryInterjection
    private let root: URL
    private var files: [URL]

    init() throws {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: "margin-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let voiceURL = try Self.makeWAV(duration: 2)
        let db = rootURL.appending(path: "library.sqlite")
        let routed = RoutedAudioPlaybackClient(speech: NoopAudioPlaybackClient(), media: AVPlayerStreamPlaybackClient())
        let appModel = Gate1AppModel(audioPlaybackClient: routed, databaseURLOverride: db)
        appModel.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let itemID = "item-pill"
        let sharedLayer = ImportedCommentaryLayer(id: "received", itemId: itemID, packageDigest: "digest-\(UUID().uuidString)", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: true, revealMode: .companion)
        let sharedRecord = ImportedCommentaryInterjection(id: "note", layerId: sharedLayer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Reviewed words", audioPath: voiceURL.path, audioDurationMs: 2_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        _ = try store.importCommentaryLayer(sharedLayer, interjections: [sharedRecord])
        appModel.selectedItem.importedCommentaryLayers = [sharedLayer]
        appModel.selectedItem.importedCommentaryInterjections = [sharedLayer.id: [sharedRecord]]
        model = appModel
        layer = sharedLayer
        record = sharedRecord
        root = rootURL
        files = [voiceURL]
    }

    /// Your own spoken Margin, with a short readable voice or a file that is not audio.
    func ownMargin(unreadable: Bool) throws -> Interjection {
        let url = try Self.makeWAV(duration: 0.5)
        files.append(url)
        if unreadable { try Data("not audio".utf8).write(to: url) }
        return Interjection(
            id: "own-margin", itemId: "item-pill", sessionId: "own-session",
            targetType: .item, targetId: "item-pill", createdAt: Date(), roughPercent: 3,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: url.path, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: "My Margin", status: "active"
        )
    }

    func cleanUp() {
        model.stopInterjectionAudioPlayback()
        for url in files + [root] { try? FileManager.default.removeItem(at: url) }
    }

    private static func makeWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-voice-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
