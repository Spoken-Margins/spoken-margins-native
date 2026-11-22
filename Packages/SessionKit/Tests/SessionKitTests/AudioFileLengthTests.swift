import Foundation
import XCTest
@testable import SessionKitAudio

/// #4924: Add Voice Margin measures a handed-over file with the system's audio reader, on real files.
final class AudioFileLengthTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "audio-length-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A 16-bit mono PCM WAV of silence, `frames` long at `rate`.
    private func wav(frames: Int, rate: Int = 8_000) -> Data {
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let dataBytes = frames * 2
        var bytes: [UInt8] = Array("RIFF".utf8) + le32(36 + dataBytes) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        bytes += Array("data".utf8) + le32(dataBytes)
        return Data(bytes) + Data(repeating: 0, count: dataBytes)
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    func testAWavReportsItsLength() throws {
        #if canImport(AVFoundation)
        let url = try write(wav(frames: 12_000), as: "a.wav") // 1.5 s at 8 kHz
        XCTAssertEqual(AudioFileLength.milliseconds(of: url), 1_500)
        #else
        throw XCTSkip("needs AVFoundation")
        #endif
    }

    func testFilesThatAreNotAudioHaveNoLength() throws {
        #if canImport(AVFoundation)
        let table: [(String, Data)] = [
            ("empty.m4a", Data()),
            ("text.m4a", Data("not audio at all".utf8)),
            ("headeronly.wav", wav(frames: 0)),
            ("truncated.wav", Data(wav(frames: 100).prefix(20))),
        ]
        for (name, data) in table {
            XCTAssertNil(AudioFileLength.milliseconds(of: try write(data, as: name)), name)
        }
        XCTAssertNil(AudioFileLength.milliseconds(of: directory.appending(path: "missing.m4a")))
        #else
        throw XCTSkip("needs AVFoundation")
        #endif
    }
}
