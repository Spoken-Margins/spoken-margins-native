import XCTest
@testable import SessionKit

/// #2694: Library audio never renders next to on-device speech, and a restored session waits for the listener.
final class LibraryAudioRenderPolicyTests: XCTestCase {
    private typealias Playback = LibraryAudioRenderPolicy.Playback

    func testTheGateDecisionTable() {
        struct Row { let name: String; let playback: Playback; let engaged: Bool; let allows: Bool }
        let rows = [
            Row(name: "speech playing", playback: .init(isPlaybackActive: true, isMedia: false, hasSession: true), engaged: true, allows: false),
            Row(name: "speech starting, first play", playback: .init(isPlaybackActive: true, isMedia: false, hasSession: true), engaged: false, allows: false),
            Row(name: "speech paused after restore", playback: .init(isPlaybackActive: false, isMedia: false, hasSession: true), engaged: false, allows: false),
            Row(name: "speech paused after the listener played or tapped offline", playback: .init(isPlaybackActive: false, isMedia: false, hasSession: true), engaged: true, allows: true),
            Row(name: "no session at launch", playback: .init(isPlaybackActive: false, isMedia: false, hasSession: false), engaged: false, allows: true),
            Row(name: "podcast playing", playback: .init(isPlaybackActive: true, isMedia: true, hasSession: true), engaged: false, allows: true),
            Row(name: "podcast paused after restore", playback: .init(isPlaybackActive: false, isMedia: true, hasSession: true), engaged: false, allows: true)
        ]
        for row in rows {
            var policy = LibraryAudioRenderPolicy()
            if row.engaged { policy.noteListenerEngaged() }
            XCTAssertEqual(policy.allowsRendering(row.playback), row.allows, row.name)
        }
    }

    func testEngagingEndsTheRestoredHoldButNotTheSpeechHold() {
        var policy = LibraryAudioRenderPolicy()
        let restored = Playback(isPlaybackActive: false, isMedia: false, hasSession: true)
        let playing = Playback(isPlaybackActive: true, isMedia: false, hasSession: true)
        XCTAssertFalse(policy.allowsRendering(restored))
        policy.noteListenerEngaged()
        XCTAssertTrue(policy.allowsRendering(restored))
        XCTAssertFalse(policy.allowsRendering(playing), "playing speech still owns the CPU, however far ahead")
    }
}
