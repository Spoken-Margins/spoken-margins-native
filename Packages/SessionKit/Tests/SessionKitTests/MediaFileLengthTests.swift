#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import SessionKitAudio

/// The length of a downloaded episode, read from the file's header (#4186). Mac only: it needs AVFoundation.
final class MediaFileLengthTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-media-length-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `seconds` of a quiet tone as AAC in an `.m4a` file. The writer is closed when this returns.
    private func writeM4A(seconds: Int) throws -> URL {
        let url = directory.appending(path: "tone-\(UUID().uuidString).m4a")
        let sampleRate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        for _ in 0..<seconds {
            let frames = AVAudioFrameCount(sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) { samples[frame] = Float(sin(Double(frame) * 0.05)) * 0.1 }
            try file.write(from: buffer)
        }
        return url
    }

    func testReadsAThreeSecondFile() async throws {
        let url = try writeM4A(seconds: 3)
        let read = await MediaFileLength.read(fileURL: url)
        let ms = try XCTUnwrap(read)
        XCTAssertEqual(Double(ms), 3_000, accuracy: 50)
    }

    /// Downloads are stored with the `.audio` extension (`PodcastDownloadCoordinator`), which names no container.
    func testReadsTheSameFileUnderTheDownloadExtension() async throws {
        let source = try writeM4A(seconds: 3)
        let renamed = directory.appending(path: "episode.audio")
        try FileManager.default.copyItem(at: source, to: renamed)
        let read = await MediaFileLength.read(fileURL: renamed)
        let ms = try XCTUnwrap(read)
        XCTAssertEqual(Double(ms), 3_000, accuracy: 50)
    }

    func testFileOfRandomBytesHasNoLength() async throws {
        let url = directory.appending(path: "noise.audio")
        try Data((0..<4_096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        let ms = await MediaFileLength.read(fileURL: url)
        XCTAssertNil(ms)
    }

    func testMissingFileHasNoLength() async {
        let ms = await MediaFileLength.read(fileURL: directory.appending(path: "absent.audio"))
        XCTAssertNil(ms)
    }

    func testIndefiniteAndNonPositiveLengthsAreRefused() {
        XCTAssertNil(MediaFileLength.milliseconds(.indefinite))
        XCTAssertNil(MediaFileLength.milliseconds(.invalid))
        XCTAssertNil(MediaFileLength.milliseconds(.zero))
        XCTAssertNil(MediaFileLength.milliseconds(CMTime(seconds: -3, preferredTimescale: 1_000)))
        XCTAssertEqual(MediaFileLength.milliseconds(CMTime(seconds: 7_200, preferredTimescale: 1_000)), 7_200_000)
    }
}
#endif
