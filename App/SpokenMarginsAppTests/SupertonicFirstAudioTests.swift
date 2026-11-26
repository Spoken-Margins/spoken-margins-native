import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest
@testable import SpokenMarginsApp

/// #842: the Supertonic client tells the start cue the moment its first sound begins, so the chime and the waiting
/// pops stop before the first word. One test lets a real, muted player reach `.playing` by itself; the others use
/// players that never play, so each status is delivered by the test and nothing else can post.
@MainActor
final class SupertonicFirstAudioTests: XCTestCase {
    private final class Posts: @unchecked Sendable {
        private let lock = NSLock()
        private var targets: [String] = []
        func add(_ target: String) { lock.withLock { targets.append(target) } }
        var all: [String] { lock.withLock { targets } }
    }

    /// The real player, muted, reaches `.playing` by itself: AVFoundation's own status posts the target, and a later
    /// `.playing` for the same play, as a second chunk's player reports, posts nothing more.
    func testTheFirstSoundOfAPlayPostsTheTargetOnce() async throws {
        let posts = Posts()
        let harness = try SupertonicClientHarness(postFirstAudio: { posts.add($0) })
        defer { harness.tearDown() }
        try await harness.start()
        try await pollUntil { !posts.all.isEmpty }
        let newest = try XCTUnwrap(harness.newestPlayer)

        harness.client.noteTimeControlStatus(.playing, of: newest)
        harness.client.noteTimeControlStatus(.playing, of: newest)

        XCTAssertEqual(posts.all, [harness.targetId], "only the first sound of the play counts")
    }

    /// Nothing has played yet, so the play is armed and waiting: only the current player reaching `.playing` posts.
    func testOnlyTheCurrentPlayerPlayingCounts() async throws {
        let posts = Posts()
        let harness = try SupertonicClientHarness(postFirstAudio: { posts.add($0) }, startsPlayers: false)
        defer { harness.tearDown() }
        try await harness.start()
        let newest = try XCTUnwrap(harness.newestPlayer)

        harness.client.noteTimeControlStatus(.playing, of: AVPlayer())
        harness.client.noteTimeControlStatus(.paused, of: newest)
        harness.client.noteTimeControlStatus(.waitingToPlayAtSpecifiedRate, of: newest)
        XCTAssertEqual(posts.all, [], "a foreign player, or a status other than playing, is not a sound")

        harness.client.noteTimeControlStatus(.playing, of: newest)
        XCTAssertEqual(posts.all, [harness.targetId], "the current player playing is")
    }

    /// A new `play` arms again: its first sound posts once more.
    func testANewPlayArmsAgain() async throws {
        let posts = Posts()
        let harness = try SupertonicClientHarness(postFirstAudio: { posts.add($0) }, startsPlayers: false)
        defer { harness.tearDown() }
        try await harness.start()
        let newest = try XCTUnwrap(harness.newestPlayer)
        harness.client.noteTimeControlStatus(.playing, of: newest)
        XCTAssertEqual(posts.all, [harness.targetId])

        try harness.play(from: 0)
        harness.client.noteTimeControlStatus(.playing, of: newest)

        XCTAssertEqual(posts.all, [harness.targetId, harness.targetId], "each play posts its own first sound")
    }

    /// A paused client has no sound to report, even if a late `.playing` arrives from the player it just paused.
    func testAPlayingNoteAfterAPauseIsNotASound() async throws {
        let posts = Posts()
        let harness = try SupertonicClientHarness(postFirstAudio: { posts.add($0) }, startsPlayers: false)
        defer { harness.tearDown() }
        try await harness.start()
        let newest = try XCTUnwrap(harness.newestPlayer)
        try harness.client.pause()

        harness.client.noteTimeControlStatus(.playing, of: newest)

        XCTAssertEqual(posts.all, [], "playback is no longer intended")
    }
}
