#if canImport(AVFoundation)
import AVFoundation
import CryptoKit
import Foundation
import XCTest
import SessionKit
import SessionKitAudio

/// #465 through real files: generated recordings written with AVFoundation (float WAV and AAC in
/// .m4a, as Margins are recorded), decoded and leveled by `MarginLoudnessLeveler`.
final class MarginLoudnessLevelerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("loudness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMeasuredLoudnessOfTheEBUReferenceSineIsMinus23() throws {
        // EBU Tech 3341 case 1: a stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS.
        let sine = (0..<(20 * 48_000)).map { Float(pow(10, -23.0 / 20) * sin(2 * .pi * 1_000 * Double($0) / 48_000)) }
        let url = folder.appendingPathComponent("reference.wav")
        try Self.write([sine, sine], to: url, aac: false)
        let measured = try MarginLoudnessLeveler.measure(fileAt: url)
        XCTAssertEqual(try XCTUnwrap(measured.integratedLUFS), -23, accuracy: 0.1)
    }

    func testAQuietRecordingIsLeveledToTheTargetAndTheRecordingIsNeverChanged() throws {
        let source = folder.appendingPathComponent("quiet.wav")
        try Self.write([Self.speechLike(seed: 1, lufs: -36)], to: source, aac: false)
        let before = try Self.hash(source)
        let destination = folder.appendingPathComponent("quiet-leveled.caf")

        let result = try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: destination)

        XCTAssertEqual(try Self.hash(source), before, "the recording is byte-for-byte unchanged")
        XCTAssertEqual(try XCTUnwrap(result.input.integratedLUFS), -36, accuracy: 0.1)
        XCTAssertEqual(result.plan.gainDB, LoudnessLeveling.maximumBoostDB, accuracy: 0.01)
        let written = try MarginLoudnessLeveler.measure(fileAt: destination)
        // 20 dB under with the 18 dB cap lands 2 LU short; allow for rounding.
        XCTAssertEqual(try XCTUnwrap(written.integratedLUFS), -16, accuracy: 2.01)
        XCTAssertLessThanOrEqual(written.truePeakDBTP, LoudnessLeveling.truePeakCeilingDBTP)
    }

    func testALoudAACRecordingIsTurnedDown() throws {
        let source = folder.appendingPathComponent("loud.m4a")
        try Self.write([Self.speechLike(seed: 2, lufs: -10)], to: source, aac: true)
        let before = try Self.hash(source)
        let destination = folder.appendingPathComponent("loud-leveled.wav")

        let result = try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: destination)

        XCTAssertEqual(try Self.hash(source), before)
        XCTAssertLessThan(result.plan.gainDB, -3)
        let written = try MarginLoudnessLeveler.measure(fileAt: destination)
        XCTAssertEqual(try XCTUnwrap(written.integratedLUFS), -16, accuracy: 2)
        XCTAssertLessThanOrEqual(written.truePeakDBTP, LoudnessLeveling.truePeakCeilingDBTP)
    }

    func testANearSilentRecordingIsBoostedLessThanTheFullAmount() throws {
        let source = folder.appendingPathComponent("hiss.wav")
        try Self.write([Self.speechLike(seed: 3, lufs: nil, speechDBFS: -50, noiseDBFS: -60, wordsPerSecond: 0.6)], to: source, aac: false)
        let result = try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: folder.appendingPathComponent("hiss-leveled.caf"))
        let integrated = try XCTUnwrap(result.input.integratedLUFS)
        let full = min(LoudnessLeveling.maximumBoostDB, LoudnessLeveling.defaultTargetLUFS - integrated)
        XCTAssertLessThan(result.plan.gainDB, full - 1)
        XCTAssertEqual(result.plan.limit, .noiseFloor)
    }

    func testTheCopyCanNeverReplaceTheRecording() throws {
        let source = folder.appendingPathComponent("margin.wav")
        try Self.write([Self.speechLike(seed: 4, lufs: -30)], to: source, aac: false)
        let before = try Self.hash(source)
        XCTAssertThrowsError(try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: source)) { error in
            XCTAssertEqual(error as? MarginLoudnessLeveler.LevelerError, .destinationIsSource)
        }
        let alias = folder.appendingPathComponent("./margin.wav")
        XCTAssertThrowsError(try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: alias))
        let link = folder.appendingPathComponent("link-to-margin.wav")
        try FileManager.default.linkItem(at: source, to: link)
        XCTAssertThrowsError(try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: link), "a hard link is the same file")
        // On the Mac's default case-insensitive disk, another spelling is the same file too.
        let otherCase = folder.appendingPathComponent("MARGIN.wav")
        if FileManager.default.fileExists(atPath: otherCase.path) {
            XCTAssertThrowsError(try MarginLoudnessLeveler.renderLeveledCopy(of: source, to: otherCase))
        }
        XCTAssertEqual(try Self.hash(source), before)
    }

    // MARK: Helpers

    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ channels: [[Float]], to url: URL, aac: Bool) throws {
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count)))
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count, AVEncoderBitRateKey: 128_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count,
               AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (index, channel) in channels.enumerated() {
            for (frame, sample) in channel.enumerated() { buffer.floatChannelData![index][frame] = sample }
        }
        try file.write(from: buffer)
        file.close()
    }

    /// Seeded syllable-like bursts over background noise, 8 s at 48 kHz, scaled to `lufs` when given.
    private static func speechLike(seed: UInt64, lufs: Double?, speechDBFS: Double = -20, noiseDBFS: Double = -85, wordsPerSecond: Double = 3.5) -> [Float] {
        let rate = 48_000.0
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let count = Int(8 * rate)
        let noise = pow(10, noiseDBFS / 20) * 3.0.squareRoot()
        var samples = (0..<count).map { _ in Float(noise * (2 * random() - 1)) }
        let speech = pow(10, speechDBFS / 20)
        var position = Int(0.2 * rate)
        while position < count {
            let length = Int((0.12 + 0.18 * random()) * rate)
            let pitch = 100 + 80 * random()
            for i in 0..<length where position + i < count {
                let t = Double(i) / rate
                var voiced = 0.0
                for harmonic in 1...6 { voiced += sin(2 * .pi * pitch * Double(harmonic) * t) / Double(harmonic) }
                samples[position + i] += Float(speech * sin(Double.pi * Double(i) / Double(length)) * (0.6 * voiced + 0.3 * (2 * random() - 1)))
            }
            position += length + Int((1 / wordsPerSecond) * rate * (0.3 + 0.7 * random()))
        }
        guard let lufs, let current = LoudnessMeter.integratedLoudness(channels: [samples], sampleRate: rate) else { return samples }
        let gain = Float(pow(10, (lufs - current) / 20))
        return samples.map { $0 * gain }
    }
}
#endif
