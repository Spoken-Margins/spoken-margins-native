import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Each audio client reports the first sound of a play so the start cue can stop at once (#842). The latch is the
/// part every client shares; the clients are checked against real players below where AVFoundation exists.
final class FirstAudioLatchTests: XCTestCase {
    func testTakeIsTrueOnceAfterEachArm() {
        var latch = FirstAudioLatch()
        XCTAssertFalse(latch.take(targetId: "a"), "nothing armed")

        latch.arm(targetId: "a")
        XCTAssertTrue(latch.take(targetId: "a"))
        XCTAssertFalse(latch.take(targetId: "a"), "only the first sound of a play counts")

        latch.arm(targetId: "a")
        XCTAssertTrue(latch.take(targetId: "a"), "a new play re-arms")
    }

    func testAnotherTargetNeitherTakesNorDisarms() {
        var latch = FirstAudioLatch()
        latch.arm(targetId: "a")

        XCTAssertFalse(latch.take(targetId: "b"))
        XCTAssertTrue(latch.take(targetId: "a"))
    }

    func testAnArmForANewTargetReplacesTheOld() {
        var latch = FirstAudioLatch()
        latch.arm(targetId: "a")
        latch.arm(targetId: "b")

        XCTAssertFalse(latch.take(targetId: "a"))
        XCTAssertTrue(latch.take(targetId: "b"))
    }

    #if canImport(Combine)
    func testTheHubDeliversEachPostedTarget() {
        let hub = FirstAudioSignals()
        var heard: [String] = []
        let subscription = hub.heard.sink { heard.append($0) }
        hub.post("one")
        hub.post("two")
        subscription.cancel()
        hub.post("three")
        XCTAssertEqual(heard, ["one", "two"])
    }
    #endif
}

#if os(macOS) && canImport(AVFoundation)
@MainActor
final class FirstAudioSignalTests: XCTestCase {
    private final class Posts: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [String] = []
        func add(_ target: String) { lock.lock(); targets.append(target); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return targets }
    }

    /// Waits for `condition` on the main run loop; the deadline is only a ceiling.
    private func waitUntil(_ message: String, timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), message)
    }

    private func makeEpisode() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "first-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try RealPlayerMarginMomentTests.writeTone(to: directory.appending(path: "episode.caf"), seconds: 8, hz: 220)
        return (directory, url)
    }

    private func configure(_ client: AVPlayerStreamPlaybackClient, url: URL) throws {
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: url.absoluteString, durationMs: 8_000,
            sourceType: .nativeMediaFile
        ))
    }

    /// The real player, muted, on a real tone file: its first `.playing` posts the target, and only once.
    func testTheStreamPlayerPostsItsTargetOnceWhenSoundBegins() throws {
        let (directory, url) = try makeEpisode()
        defer { try? FileManager.default.removeItem(at: directory) }
        let posts = Posts()
        let client = AVPlayerStreamPlaybackClient(postFirstAudio: { posts.add($0) })
        try configure(client, url: url)
        defer { try? client.stop() }

        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)

        waitUntil("the player reached .playing and posted") { !posts.all.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(posts.all, ["episode-target"], "one post for one play, however often the status settles")
    }

    /// An engine seek or resume goes through `play` again, so it posts again; the watch ignores it with no open start.
    func testASecondPlayOnTheSameClientPostsAgain() throws {
        let (directory, url) = try makeEpisode()
        defer { try? FileManager.default.removeItem(at: directory) }
        let posts = Posts()
        let client = AVPlayerStreamPlaybackClient(postFirstAudio: { posts.add($0) })
        try configure(client, url: url)
        defer { try? client.stop() }

        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)
        waitUntil("the first play posted") { posts.all.count == 1 }
        try client.pause()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        try client.play(targetId: "episode-target", fromMediaTimeMs: 1_000)

        waitUntil("the second play posted") { posts.all.count == 2 }
        XCTAssertEqual(posts.all, ["episode-target", "episode-target"])
    }

    /// Audit of #5012: a `.playing` change queued before a `play` arrived is handled after it. It must not take the
    /// latch of the new start. The item here never loads, so the player is never `.playing` when its note is handled:
    /// a note for it posts nothing, and neither does a note for a player that is playing but is not the client's.
    func testAStaleOrForeignPlayingNoteDoesNotTakeTheNewStartsLatch() throws {
        let (directory, tone) = try makeEpisode()
        defer { try? FileManager.default.removeItem(at: directory) }
        let posts = Posts()
        let client = AVPlayerStreamPlaybackClient(postFirstAudio: { posts.add($0) })
        try client.setPlaybackVolume(0)
        let missing = FileManager.default.temporaryDirectory.appending(path: "first-audio-missing-\(UUID().uuidString).caf")
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: missing.absoluteString, durationMs: 8_000,
            sourceType: .nativeMediaFile
        ))
        defer { try? client.stop() }
        try? client.play(targetId: "episode-target", fromMediaTimeMs: 0) // arms; nothing can sound

        let current = try XCTUnwrap(client.debugPlayer)
        XCTAssertNotEqual(current.timeControlStatus, .playing, "the item cannot play")
        client.noteFirstSound(of: current)
        XCTAssertEqual(posts.all, [], "the current player is not playing: a stale note")

        // A player that really is playing but is not the client's (the old item's player) is not this start's sound.
        let foreign = AVPlayer(url: tone)
        foreign.volume = 0
        foreign.play()
        defer { foreign.pause() }
        waitUntil("the foreign player is playing") { foreign.timeControlStatus == .playing }
        client.noteFirstSound(of: foreign)

        XCTAssertEqual(posts.all, [], "no sound has begun for this start")
    }

    /// Audit of #5012, the reverse: a `play` on a target that is already sounding makes no new `.playing` change, so
    /// it must not arm a latch that a later rebuffer would take and post late.
    func testAPlayOnATargetThatIsAlreadySoundingDoesNotArm() throws {
        let (directory, url) = try makeEpisode()
        defer { try? FileManager.default.removeItem(at: directory) }
        let posts = Posts()
        let client = AVPlayerStreamPlaybackClient(postFirstAudio: { posts.add($0) })
        try configure(client, url: url)
        defer { try? client.stop() }
        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)
        waitUntil("the first play posted") { posts.all.count == 1 }
        let current = try XCTUnwrap(client.debugPlayer)
        XCTAssertEqual(current.timeControlStatus, .playing)

        try client.play(targetId: "episode-target", fromMediaTimeMs: 0) // no pause between: still sounding
        client.noteFirstSound(of: current) // a later `.playing`, as after a rebuffer

        XCTAssertEqual(posts.all, ["episode-target"], "the second play had no first sound to report")
    }

    /// The system voice, with its synthesizer's callbacks delivered by the test (the pattern of #1129 and #3928).
    func testTheSystemVoicePostsOnDidStartOncePerPlay() throws {
        let posts = Posts()
        let speech = SystemSpeechPlaybackClient(
            voiceIdentifier: nil, speechRate: AVSpeechUtteranceDefaultSpeechRate,
            postFirstAudio: { posts.add($0) }
        )
        var queued: [(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance)] = []
        speech.speakNarration = { queued.append(($0, $1)) } // nothing is spoken
        _ = try speech.prepareSpeechText("First sentence. Second sentence.")

        try speech.play(targetId: "text-target")
        XCTAssertEqual(posts.all, [], "queued, not yet speaking")
        let first = try XCTUnwrap(queued.first)
        speech.speechSynthesizer(first.synthesizer, didStart: first.utterance)
        XCTAssertEqual(posts.all, ["text-target"])

        speech.speechSynthesizer(first.synthesizer, didStart: first.utterance)
        XCTAssertEqual(posts.all, ["text-target"], "a second didStart without a new play posts nothing")

        queued.removeAll()
        try speech.play(targetId: "text-target")
        let again = try XCTUnwrap(queued.first)
        speech.speechSynthesizer(again.synthesizer, didStart: again.utterance)
        XCTAssertEqual(posts.all, ["text-target", "text-target"], "each play re-arms")
    }
}
#endif
