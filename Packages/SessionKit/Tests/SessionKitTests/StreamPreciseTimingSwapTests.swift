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
        client.vbrProbe = MP3VBRHeaderProbe { _, start, n in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let answer else { throw URLError(.timedOut) }
            return Data(answer.dropFirst(start).prefix(n))
        }
        return client
    }

    private func start(_ client: AVPlayerStreamPlaybackClient, hangingAt port: UInt16? = nil) throws {
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "e", targetType: .transcriptBackedMedia, targetId: "t", title: "T",
            playbackURL: port.map { "http://127.0.0.1:\($0)/episode.mp3" } ?? url, durationMs: 600_000,
            sourceType: .nativeMediaFile
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

    /// Audit finding 1 on #2687: a late answer re-entered play(), which marked the listener's pending seek
    /// "media_seek_superseded" and read the new player's clock for it. The answer lands at an exact moment here
    /// (cache set, then the callback runs) because a seek on an unreachable stream settles by itself within 100 ms.
    func testALateAnswerNeverSupersedesAPendingNavigationSeek() throws {
        let c = client(answer: nil)
        defer { try? c.stop() }
        try start(c)
        let request = try c.requestMediaSeek(toMediaTimeMs: 200_000)
        XCTAssertTrue(c.hasPendingSeekForTesting, "precondition: the listener's seek is pending")
        let item = URL(string: url)!
        c.vbrProbe.record(true, for: item)
        c.probeAnswered(for: item)
        XCTAssertFalse(c.currentItemWasBuiltKeyedForTesting, "no swap while a seek is pending")
        if case .failed(_, let reason) = c.mediaSeekResolution(for: request) {
            XCTFail("the listener's seek was reported failed: \(reason)")
        }
    }

    /// The engine's own start seek counts too: a cold stream keeps it pending while it buffers.
    func testALateAnswerNeverSupersedesThePendingStartSeek() throws {
        let c = client(answer: nil)
        defer { try? c.stop() }
        try start(c)
        XCTAssertTrue(c.hasPendingSeekForTesting, "precondition: the start seek is still pending")
        let item = URL(string: url)!
        c.vbrProbe.record(true, for: item)
        c.probeAnswered(for: item)
        XCTAssertFalse(c.currentItemWasBuiltKeyedForTesting)
    }

    /// A second seek made while one is unsettled does not rebuild the player under it either.
    func testARapidSecondSeekDoesNotRebuildUnderThePendingOne() throws {
        let c = client(answer: nil)
        defer { try? c.stop() }
        try start(c)
        _ = try c.requestMediaSeek(toMediaTimeMs: 100_000)
        c.vbrProbe.record(true, for: URL(string: url)!)
        _ = try c.requestMediaSeek(toMediaTimeMs: 120_000)
        XCTAssertFalse(c.currentItemWasBuiltKeyedForTesting, "left for the next settled seek")
    }

    // Finding 2: a tag with cover art far past any read cap still gets its frame read, from the tag's end.
    func testALargeID3TagIsSkippedByRangeNotRead() async {
        var file = Data("ID3".utf8) + Data([4, 0, 0])
        let size = 700_000
        file.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        file.append(Data(count: size))
        file.append(tagged("Xing"))
        let served = Served()
        let url = URL(string: "https://example.com/art.mp3")!
        let bytes = file
        let p = MP3VBRHeaderProbe { _, start, n in served.add(start, n); return Data(bytes.dropFirst(start).prefix(n)) }
        await p.prefetch(url)?.value
        XCTAssertEqual(p.cachedAnswer(for: url), true)
        XCTAssertEqual(served.total, 4096 * 2, "two small reads, not the tag")
        XCTAssertEqual(served.starts, [0, size + 10])
    }

    func testAServerThatIgnoresRangeFailsSafeToNoKey() async {
        var file = Data("ID3".utf8) + Data([4, 0, 0, 0, 0x2B, 0x4E, 0x20]) // a large tag
        file.append(Data(count: 700_000))
        let url = URL(string: "https://example.com/norange.mp3")!
        // Ignores the start and always serves from byte 0, as a server answering 200 would.
        let bytes = file
        let p = MP3VBRHeaderProbe { _, _, n in Data(bytes.prefix(n)) }
        await p.prefetch(url)?.value
        XCTAssertNotEqual(p.cachedAnswer(for: url), true)
    }

    func testNonNetworkAndNonMP3URLsAreNotProbed() {
        let p = MP3VBRHeaderProbe { _, _, _ in XCTFail("probed"); return Data() }
        XCTAssertNil(p.prefetch(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertNil(p.prefetch(URL(string: "https://example.com/a.m4a?x=1")!))
        XCTAssertNil(p.prefetch(URL(string: "https://example.com/live.m3u8")!))
        XCTAssertTrue(MP3VBRHeaderProbe.shouldProbe(URL(string: "https://example.com/download?id=7")!), "unknown extension still probes")
        XCTAssertTrue(MP3VBRHeaderProbe.shouldProbe(URL(string: "https://example.com/a.MP3")!))
    }
}

private final class Served: @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [(Int, Int)] = []
    func add(_ start: Int, _ n: Int) { lock.lock(); reads.append((start, n)); lock.unlock() }
    var starts: [Int] { lock.lock(); defer { lock.unlock() }; return reads.map(\.0) }
    var total: Int { lock.lock(); defer { lock.unlock() }; return reads.reduce(0) { $0 + $1.1 } }
}
