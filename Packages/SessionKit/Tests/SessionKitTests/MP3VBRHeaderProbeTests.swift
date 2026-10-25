import XCTest
@testable import SessionKitAudio

/// Generated MP3 first frames (#2660). Only the 4-byte header and the tag position matter to the parser.
final class MP3VBRHeaderProbeTests: XCTestCase {
    /// version: 3 MPEG1, 2 MPEG2, 0 MPEG2.5. Layer III, a valid bitrate index and sample-rate index.
    private func frame(version: UInt8 = 3, mono: Bool = false, crc: Bool = false, tag: String?, tagAt: Int? = nil, vbri: Bool = false) -> Data {
        var d = Data([0xFF, 0xE0 | (version << 3) | (0x1 << 1) | (crc ? 0 : 1), 0x90, mono ? 0xC0 : 0x00])
        let side = version == 3 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        let at = tagAt ?? (4 + (crc ? 2 : 0) + side)
        d.append(Data(count: at - 4))
        if let tag { d.append(Data(tag.utf8)) }
        d.append(Data(count: 200))
        if vbri { d.replaceSubrange(36..<40, with: Data("VBRI".utf8)) }
        return d
    }

    private func id3(size: Int, footer: Bool = false) -> Data {
        var d = Data("ID3".utf8) + Data([4, 0, footer ? 0x10 : 0])
        d.append(contentsOf: [UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
        return d + Data(count: size) + (footer ? Data(count: 10) : Data())
    }

    func testTableOfHeaders() {
        let cases: [(String, Data, MP3FirstFrameHeader)] = [
            ("MPEG1 stereo Xing", frame(tag: "Xing"), .xing),
            ("MPEG1 stereo Info", frame(tag: "Info"), .info),
            ("MPEG1 mono Xing", frame(mono: true, tag: "Xing"), .xing),
            ("MPEG2 stereo Xing", frame(version: 2, tag: "Xing"), .xing),
            ("MPEG2 mono Xing", frame(version: 2, mono: true, tag: "Xing"), .xing),
            ("MPEG2.5 mono Xing", frame(version: 0, mono: true, tag: "Xing"), .xing),
            ("CRC shifts the tag by two", frame(crc: true, tag: "Xing"), .xing),
            ("VBRI at 36", frame(tag: nil, vbri: true), .vbri),
            ("no header", frame(tag: nil), .none),
            ("tag at the wrong offset is not a tag", frame(tag: "Xing", tagAt: 30), .none),
            ("ID3 before the frame", id3(size: 500) + frame(tag: "Xing"), .xing),
            ("ID3 with footer", id3(size: 40, footer: true) + frame(tag: "Xing"), .xing),
            ("garbage", Data(repeating: 0x41, count: 5000), .none),
            ("zero padding then a frame", Data(count: 100) + frame(tag: "Xing"), .xing),
            ("empty", Data(), .needMoreData(minimumLength: 4096)),
        ]
        for (name, data, expected) in cases {
            XCTAssertEqual(MP3VBRHeaderParser.parse(data), expected, name)
        }
    }

    func testTruncatedDataAsksForMore() {
        let full = frame(tag: "Xing")
        if case .needMoreData(let n) = MP3VBRHeaderParser.parse(full.prefix(20)) { XCTAssertEqual(n, 40) } else { XCTFail("truncated frame") }
        if case .needMoreData(let n) = MP3VBRHeaderParser.parse(Data("ID3".utf8)) { XCTAssertEqual(n, 10) } else { XCTFail("truncated id3") }
        if case .needMoreData(let n) = MP3VBRHeaderParser.parse(id3(size: 6000).prefix(100)) { XCTAssertGreaterThan(n, 6000) } else { XCTFail("tag past the read") }
    }

    func testOnlyXingAndVBRIWarrantTheKey() {
        XCTAssertTrue(MP3VBRHeaderParser.warrantsPreciseTiming(.xing))
        XCTAssertTrue(MP3VBRHeaderParser.warrantsPreciseTiming(.vbri))
        XCTAssertFalse(MP3VBRHeaderParser.warrantsPreciseTiming(.info))
        XCTAssertFalse(MP3VBRHeaderParser.warrantsPreciseTiming(.none))
        XCTAssertFalse(MP3VBRHeaderParser.warrantsPreciseTiming(.needMoreData(minimumLength: 9)))
    }

    private func probe(_ data: Data, counter: Counter = Counter()) -> MP3VBRHeaderProbe {
        MP3VBRHeaderProbe { _, start, n in counter.add(start); return Data(data.dropFirst(start).prefix(n)) }
    }

    func testProbeCachesXingAndFollowsALargeID3Tag() async {
        let url = URL(string: "https://example.com/a.mp3")!
        let counter = Counter()
        let p = probe(id3(size: 9000) + frame(tag: "Xing"), counter: counter)
        XCTAssertNil(p.cachedAnswer(for: url), "unknown before the probe finishes: play without the key")
        await p.prefetch(url)?.value
        XCTAssertEqual(p.cachedAnswer(for: url), true)
        XCTAssertEqual(counter.values.count, 2, "second, larger read for the tag")
        await p.prefetch(url)?.value
        XCTAssertEqual(counter.values.count, 2, "cached per URL")
    }

    func testOtherStreamsGetNoKey() async {
        let url = URL(string: "https://example.com/cbr.mp3")!
        let p = probe(frame(tag: "Info"))
        await p.prefetch(url)?.value
        XCTAssertEqual(p.cachedAnswer(for: url), false)
        XCTAssertFalse(AVPlayerStreamPlaybackClient.wantsPreciseTiming(for: url, probe: p))
    }

    func testFailedProbePlaysAsToday() async {
        let url = URL(string: "https://example.com/down.mp3")!
        let p = MP3VBRHeaderProbe { _, _, _ in throw URLError(.timedOut) }
        await p.prefetch(url)?.value
        XCTAssertNil(p.cachedAnswer(for: url))
        XCTAssertFalse(AVPlayerStreamPlaybackClient.wantsPreciseTiming(for: url, probe: p))
    }

    func testVBRStreamAndFilesGetTheKeyOthersDoNot() async {
        let url = URL(string: "https://example.com/vbr.mp3")!
        let p = probe(frame(tag: "Xing"))
        XCTAssertFalse(AVPlayerStreamPlaybackClient.wantsPreciseTiming(for: url, probe: p), "before the probe")
        await p.prefetch(url)?.value
        XCTAssertTrue(AVPlayerStreamPlaybackClient.wantsPreciseTiming(for: url, probe: p))
        XCTAssertTrue(AVPlayerStreamPlaybackClient.wantsPreciseTiming(for: URL(fileURLWithPath: "/tmp/a.mp3"), probe: p))
        XCTAssertNil(p.prefetch(URL(fileURLWithPath: "/tmp/a.mp3")), "files are never probed")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ n: Int) { lock.lock(); stored.append(n); lock.unlock() }
}
