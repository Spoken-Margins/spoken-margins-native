import Foundation
import SessionKit
import XCTest

final class DownloadedAudioSnifferTests: XCTestCase {
    private func text(_ string: String) -> Data { Data(string.utf8) }

    private func bytes(hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: What a 200 response with no episode in it looks like

    func testWebPagesAndMessagesAreText() {
        let signIn = "<!DOCTYPE html>\n<html><head><title>Hotel Wi-Fi</title></head><body>Sign in to continue</body></html>"
        let cases: [String: String] = [
            "html page": signIn,
            "html in capitals": signIn.uppercased(),
            "html with leading blank lines": "\n\n  \t" + signIn,
            "html with windows line breaks": signIn.replacingOccurrences(of: "\n", with: "\r\n"),
            "html after a byte order mark": "\u{FEFF}" + signIn,
            "xml error body": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>AccessDenied</Code></Error>",
            "json error body": "{\"error\":\"forbidden\",\"status\":403}",
            "plain text error": "403 Forbidden",
            "single word": "Forbidden",
            "page with accented and Japanese text": "<html><body>Café ログインしてください</body></html>",
            "base64 text pretending to be a file": String(repeating: "QUJDREVGRw==", count: 100),
        ]
        for (name, body) in cases {
            XCTAssertTrue(DownloadedAudioSniffer.looksLikeText(text(body)), name)
        }
    }

    func testOnlyTheStartOfALongPageIsLookedAt() {
        let page = "<html><body>" + String(repeating: "Please sign in. ", count: 2_000) + "</body></html>"
        XCTAssertGreaterThan(page.utf8.count, 10_000)
        XCTAssertTrue(DownloadedAudioSniffer.looksLikeText(text(page)))
    }

    func testAMultiByteCharacterCutAtTheEndOfThePrefixStillReadsAsText() {
        // 511 ASCII bytes, then a three-byte character that straddles the 512-byte cut.
        let page = String(repeating: "a", count: 511) + "日本語"
        XCTAssertTrue(DownloadedAudioSniffer.looksLikeText(text(page)))
    }

    // MARK: Real audio is never called text

    func testTheFirstBytesOfRealAudioFilesAreNotText() {
        // The first 24 bytes of files written by ffmpeg, one per container the app plays.
        let headers: [String: String] = [
            "mp3 with an ID3 tag": "49443304000000000023545353450000000f0000034c6176",
            "m4a": "0000001c667479704d344120000002004d34412069736f6d",
            "wav": "5249464656b1020057415645666d74201000000001000100",
            "ogg vorbis": "4f67675300020000000000000000e70f6ae900000000d9b1",
            "ogg opus": "4f676753000200000000000000003f1d8a1400000000eff4",
            "flac": "664c614300000022120012000001310004f50ac440f00001",
            "aac in adts": "fff15040213ffcde02004c61766336302e33312e31303200",
        ]
        for (name, hex) in headers {
            XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(bytes(hex: hex)), name)
        }
    }

    func testAudioSignaturesFollowedByHighEntropyBytesAreNotText() {
        // Container signatures that are themselves printable (RIFF, ID3, OggS, fLaC, FORM) must still
        // not read as text once the binary fields that follow them are there.
        let signatures: [String: Data] = [
            "RIFF": Data("RIFF".utf8), "ID3": Data("ID3".utf8), "OggS": Data("OggS".utf8),
            "fLaC": Data("fLaC".utf8), "FORM": Data("FORM".utf8), "ftyp": Data("ftyp".utf8),
            "MPEG frame sync": Data([0xFF, 0xFB]),
        ]
        var generator = SplitMix(seed: 0xA0D1_0919)
        for (name, signature) in signatures {
            var data = signature
            while data.count < 4_096 { data.append(UInt8(truncatingIfNeeded: generator.next())) }
            XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(data), name)
        }
    }

    func testPseudoRandomAudioLikeBytesAreNeverText() {
        var generator = SplitMix(seed: 919)
        for round in 0..<200 {
            var data = Data()
            while data.count < 1_024 { data.append(UInt8(truncatingIfNeeded: generator.next())) }
            XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(data), "round \(round)")
        }
    }

    func testSilentAndTinyBinaryFilesAreNotText() {
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(Data(count: 2_048)), "digital silence")
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(Data([1, 2, 3])), "the stand-in bytes the coordinator tests use")
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(Data([0xFF, 0xFB, 0x90, 0x00])), "a bare MPEG frame header")
    }

    // MARK: Neighbouring inputs

    func testEmptyIsNotText() {
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(Data()))
    }

    func testEveryControlByteMakesTheStartBinary() {
        let allowed: Set<UInt8> = [0x09, 0x0A, 0x0D]
        for byte in (0...0x1F).map(UInt8.init) + [0x7F] {
            let data = text("<html>") + Data([byte]) + text("</html>")
            XCTAssertEqual(DownloadedAudioSniffer.looksLikeText(data), allowed.contains(byte), "byte \(byte)")
        }
    }

    func testABinaryByteJustInsideThePrefixDecidesAndOneJustOutsideDoesNot() {
        let inside = text(String(repeating: "a", count: DownloadedAudioSniffer.prefixLength - 1)) + Data([0x00])
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(inside))
        let outside = text(String(repeating: "a", count: DownloadedAudioSniffer.prefixLength)) + Data([0x00])
        XCTAssertTrue(DownloadedAudioSniffer.looksLikeText(outside))
    }

    // MARK: Files

    func testAFileIsJudgedByItsStartWhateverItIsCalled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "downloaded-audio-sniffer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = directory.appending(path: "episode.mp3")
        try text("<html><body>Sign in</body></html>").write(to: page)
        XCTAssertTrue(DownloadedAudioSniffer.looksLikeText(fileAt: page), "an .mp3 that holds a web page")

        let audio = directory.appending(path: "episode.html")
        try bytes(hex: "5249464656b1020057415645666d74201000000001000100").write(to: audio)
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(fileAt: audio), "a .html that holds a WAV header")

        let empty = directory.appending(path: "empty.audio")
        try Data().write(to: empty)
        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(fileAt: empty))

        XCTAssertFalse(DownloadedAudioSniffer.looksLikeText(fileAt: directory.appending(path: "missing.mp3")),
                       "a file that can't be read is not called text")
    }
}

/// A fixed-seed generator so the "never text" rounds are the same on every run and every platform.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
