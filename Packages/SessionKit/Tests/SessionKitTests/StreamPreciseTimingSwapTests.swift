import XCTest
import SessionKit
@testable import SessionKitAudio

/// #2660: the probe answers after `play` has built its first item (the engine calls configureMediaContext and
/// play back to back), so the key has to reach the item that is already playing.
final class StreamPreciseTimingSwapTests: XCTestCase {
    private let url = "http://127.0.0.1:9/episode.mp3"

    private func tagged(_ tag: String) -> Data {
        var d = Data([0xFF, 0xFB, 0x90, 0x00])
        d.append(Data(count: 32))
        d.append(Data(tag.utf8))
        d.append(Data(count: 200))
        return d
    }

    private func spin(until seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func client(answer: Data?, delay: TimeInterval = 0.3) -> AVPlayerStreamPlaybackClient {
        let client = AVPlayerStreamPlaybackClient()
        client.vbrProbe = MP3VBRHeaderProbe { _, n in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let answer else { throw URLError(.timedOut) }
            return answer.prefix(n)
        }
        return client
    }

    private func start(_ client: AVPlayerStreamPlaybackClient) throws {
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "e", targetType: .transcriptBackedMedia, targetId: "t", title: "T",
            playbackURL: url, durationMs: 600_000, sourceType: .nativeMediaFile
        ))
        try client.play(targetId: "t", fromMediaTimeMs: 90_000)
    }

    func testColdPlayOfAVBRStreamEndsUpKeyed() throws {
        let c = client(answer: tagged("Xing"))
        defer { try? c.stop() }
        try start(c)
        XCTAssertEqual(c.currentItemWasBuiltKeyedForTesting, false, "the first item is built before the answer")
        XCTAssertTrue(spin(until: 4) { c.currentItemWasBuiltKeyedForTesting }, "the playing item gets the key")
    }

    func testNonVBRAndFailedProbesNeverSwap() throws {
        for answer in [tagged("Info"), nil] as [Data?] {
            let c = client(answer: answer, delay: 0.1)
            defer { try? c.stop() }
            try start(c)
            _ = spin(until: 1) { false }
            XCTAssertFalse(c.currentItemWasBuiltKeyedForTesting)
        }
    }

    func testAnAnswerAfterTheWindowWaitsForTheNextDeliberateSeek() throws {
        let c = client(answer: tagged("Xing"), delay: 0.2)
        c.preciseTimingSwapWindow = 0
        defer { try? c.stop() }
        try start(c)
        _ = spin(until: 1) { false }
        XCTAssertEqual(c.currentItemWasBuiltKeyedForTesting, false, "no swap under audible audio")
        _ = try c.requestMediaSeek(toMediaTimeMs: 30_000)
        XCTAssertEqual(c.currentItemWasBuiltKeyedForTesting, true, "a navigation seek rebuilds the item keyed")
    }

    func testNonNetworkAndNonMP3URLsAreNotProbed() {
        let p = MP3VBRHeaderProbe { _, _ in XCTFail("probed"); return Data() }
        XCTAssertNil(p.prefetch(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertNil(p.prefetch(URL(string: "https://example.com/a.m4a?x=1")!))
        XCTAssertNil(p.prefetch(URL(string: "https://example.com/live.m3u8")!))
        XCTAssertTrue(MP3VBRHeaderProbe.shouldProbe(URL(string: "https://example.com/download?id=7")!), "unknown extension still probes")
        XCTAssertTrue(MP3VBRHeaderProbe.shouldProbe(URL(string: "https://example.com/a.MP3")!))
    }
}
