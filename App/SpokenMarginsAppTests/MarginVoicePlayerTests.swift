import AVFoundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// The voice player on its own (#993), with a scripted host and a real `AVPlayer` on real WAV files. The model-level
/// behaviour is in `MarginVoiceTransportTests` and `SharedMarginReturnAppTests`; these pin the rules the player
/// applies itself, each of which fails when the line that implements it is removed.
@MainActor
final class MarginVoicePlayerTests: XCTestCase {
    private var files: [URL] = []

    override func tearDownWithError() throws {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        try super.tearDownWithError()
    }

    /// Heard fires once, when the clock first moves, and the end fires once, at the end of the clip: not before,
    /// not twice. (Fails if the `!heard` latch is removed, if `current > 0` stops being required, or if the end rule's
    /// 0.05 s tolerance is widened past a clip's length.)
    func testASharedVoiceIsHeardOnceAndEndsOnce() throws {
        let host = ScriptedVoiceHost()
        defer { withExtendedLifetime(host) {} }
        let player = MarginVoicePlayer(host: host)
        let wav = try makeWAV(duration: 1)
        try player.prepareShared(try makePrompt(voice: wav), url: { wav }, rate: 1,
                                 mixesWithOtherAudio: false, lowersBackgroundAudio: false, mixedPlaybackVolume: 1)
        XCTAssertEqual(host.heard.count, 0, "asking to play is not hearing it")
        XCTAssertEqual(host.sharedEnded, 0)
        player.beginShared(installRemoteControls: false)
        defer { player.resetSharedState(); player.releasePlayer() }

        try waitUntil("the voice ends", timeout: 8) { host.sharedEnded > 0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(host.heard.count, 1, "heard once however many polls saw the clock move")
        XCTAssertEqual(host.sharedEnded, 1, "the end is reported once; the poll stops after it")
    }

    /// A voice that cannot be decoded is never heard and never ends: the player stops itself and its poll,
    /// keeps the Margin on screen (Retry and Return to Source) and shows the failure.
    func testAFailedSharedVoiceStopsThePlayerAndThePollButKeepsTheCard() throws {
        let host = ScriptedVoiceHost()
        defer { withExtendedLifetime(host) {} }
        let player = MarginVoicePlayer(host: host)
        let wav = try makeWAV(duration: 1)
        try Data("not audio".utf8).write(to: wav)
        let prompt = try makePrompt(voice: wav)
        try player.prepareShared(prompt, url: { wav }, rate: 1,
                                 mixesWithOtherAudio: false, lowersBackgroundAudio: false, mixedPlaybackVolume: 1)
        player.beginShared(installRemoteControls: false)
        defer { player.resetSharedState(); player.releasePlayer() }
        let poll = try XCTUnwrap(player.completionTask)
        XCTAssertEqual(player.sharedPhase, .loading)

        try waitUntil("the failure shows", timeout: 12) { player.sharedPhase.isFailed }

        XCTAssertNil(player.currentPlayer, "the failed player is released")
        XCTAssertNil(player.completionTask)
        XCTAssertTrue(poll.isCancelled, "the poll was cancelled, not only forgotten")
        XCTAssertFalse(player.sharedIsPaused)
        XCTAssertEqual(player.sharedMargin?.id, prompt.id, "the card stays so Retry is offered")
        XCTAssertEqual(host.heard.count, 0, "a voice that never played stays new")
        XCTAssertEqual(host.sharedEnded, 0, "a failure is not an ending, so it never resumes the source")
    }

    /// Stopping cancels the poll and forgets everything the player published, in both routes.
    func testStoppingCancelsThePollAndClearsWhatWasPublished() throws {
        let host = ScriptedVoiceHost()
        defer { withExtendedLifetime(host) {} }
        let player = MarginVoicePlayer(host: host)
        let wav = try makeWAV(duration: 3)
        try player.prepareShared(try makePrompt(voice: wav), url: { wav }, rate: 1.5,
                                 mixesWithOtherAudio: false, lowersBackgroundAudio: false, mixedPlaybackVolume: 1)
        player.beginShared(installRemoteControls: false)
        let poll = try XCTUnwrap(player.completionTask)
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertNotNil(player.currentPlayer)

        player.resetSharedState()
        player.releasePlayer()

        XCTAssertNil(player.sharedMargin)
        XCTAssertNil(player.health)
        XCTAssertEqual(player.sharedPhase, .loading)
        XCTAssertFalse(player.sharedIsPaused)
        XCTAssertNil(player.currentPlayer)
        XCTAssertNil(player.completionTask)
        XCTAssertTrue(poll.isCancelled)
        XCTAssertNil(player.ownMarginID)
        XCTAssertNil(player.ownMarginSessionID)
        XCTAssertEqual(player.rate, 1)
    }

    /// The paused flag and the phase are separate writes: the listener's pause sets both, the system pausing the
    /// player moves only the phase (it reads Paused and resumes in place), and a failure clears only the flag.
    func testThePausedFlagAndThePhaseAreIndependentWrites() throws {
        let host = ScriptedVoiceHost()
        defer { withExtendedLifetime(host) {} }
        let player = MarginVoicePlayer(host: host)
        let wav = try makeWAV(duration: 5)
        try player.prepareShared(try makePrompt(voice: wav), url: { wav }, rate: 1,
                                 mixesWithOtherAudio: false, lowersBackgroundAudio: false, mixedPlaybackVolume: 1)
        player.beginShared(installRemoteControls: false)
        defer { player.resetSharedState(); player.releasePlayer() }
        try waitUntil("its clock advances") { player.sharedPhase == .playing }

        try player.setSharedPaused(true)
        XCTAssertTrue(player.sharedIsPaused)
        XCTAssertEqual(player.sharedPhase, .paused)
        try player.setSharedPaused(false)
        XCTAssertFalse(player.sharedIsPaused)
        try waitUntil("it plays again") { player.sharedPhase == .playing }

        player.currentPlayer?.pause() // the system's pause: nobody told the player
        try waitUntil("it reads Paused") { player.sharedPhase == .paused }
        XCTAssertFalse(player.sharedIsPaused, "the listener did not pause it")
    }

    /// Your own Margin and a shared Margin publish separate state: starting your own leaves the shared state alone.
    func testOwnMarginPlaybackPublishesItsIdentityAndRate() throws {
        let host = ScriptedVoiceHost()
        defer { withExtendedLifetime(host) {} }
        let player = MarginVoicePlayer(host: host)
        let wav = try makeWAV(duration: 3)
        let own = Interjection(
            id: "own", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(), roughPercent: 0,
            anchor: Anchor(anchorType: .transcript, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 1_000),
            audioPath: wav.path, audioStatus: "recorded", transcriptionStatus: "complete",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active"
        )
        var urlCalled = false
        try player.startOwn(own, url: { urlCalled = true; return wav }, rate: 2)
        defer { player.releasePlayer() }

        XCTAssertTrue(urlCalled)
        XCTAssertTrue(player.isPlayingOwn(own))
        XCTAssertEqual(player.ownMarginID, "own")
        XCTAssertEqual(player.ownMarginSessionID, "session")
        XCTAssertEqual(player.rate, 2)
        XCTAssertNil(player.sharedMargin)
        XCTAssertNotNil(player.completionTask)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func makePrompt(voice: URL) throws -> ImportedCommentaryPrompt {
        let layer = ImportedCommentaryLayer(id: "received", itemId: "item-pill", packageDigest: "digest-\(UUID().uuidString)", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Source"),
            displayLabel: "Reviewer", importedAt: Date(), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: true, revealMode: .companion)
        let record = ImportedCommentaryInterjection(id: "note", layerId: layer.id, packageScopedId: "note", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Reviewed words", audioPath: voice.path, audioDurationMs: 1_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        return ImportedCommentaryPrompt(layer: layer, interjection: record, index: 1, count: 1)
    }

    private func makeWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "margin-voice-player-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        files.append(url)
        return url
    }
}

/// Records what the player asks of its host. It never resumes anything, as the real host's callbacks must not.
@MainActor
private final class ScriptedVoiceHost: MarginVoicePlayerHost {
    var marginVoiceMixesWithOtherAudio = false
    private(set) var heard: [String] = []
    private(set) var sharedEnded = 0
    private(set) var ownEnded = 0
    private(set) var ownFailed = 0
    private(set) var remoteCommands: [CompactControlCommand] = []

    func marginVoiceOwnPlaybackEnded() { ownEnded += 1 }
    func marginVoiceOwnPlaybackFailed() { ownFailed += 1 }
    func marginVoiceSharedMarginHeard(_ margin: ImportedCommentaryInterjection) { heard.append(margin.id) }
    func marginVoiceSharedPlaybackEnded() { sharedEnded += 1 }
    func marginVoiceRemoteCommand(_ command: CompactControlCommand) { remoteCommands.append(command) }
}
