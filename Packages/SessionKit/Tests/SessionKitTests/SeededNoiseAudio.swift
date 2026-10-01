#if canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest

/// Test audio that never repeats unless asked to: a gated, gliding tone over seeded noise.
///
/// Acoustic-anchor tests need this. A tone fixture that repeated every 23 s let both flanks of an anchor
/// match the same wrong copy, so a test's verdict depended on which copy ShazamKit found first (#296).
/// Low-rate mono AAC keeps generation quick; the seed makes every run identical.
enum SeededNoiseAudio {
    static let defaultSeed: UInt64 = 0x9E3779B97F4A7C15

    /// One stretch of audio. Two equal sections are the same audio, so listing a section twice repeats it.
    struct Section: Equatable {
        var seed: UInt64 = defaultSeed
        var startSecond = 0
        var seconds: Int
    }

    /// Writes `seconds` of audio. A different `seed` or `startSecond` gives audio unlike the default's.
    static func write(to url: URL, seconds: Int, seed: UInt64 = defaultSeed, startSecond: Int = 0) throws {
        try write(to: url, sections: [Section(seed: seed, startSecond: startSecond, seconds: seconds)])
    }

    /// Writes the sections back to back, for an edition in which some audio repeats (a theme, sting or bumper).
    static func write(to url: URL, sections: [Section]) throws {
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        let frames = AVAudioFrameCount(sampleRate)
        for section in sections {
            var state = section.seed
            for second in section.startSecond..<(section.startSecond + section.seconds) {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for frame in 0..<Int(frames) {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let noise = Double(Int64(bitPattern: state >> 11)) / Double(1 << 52) - 1
                    let time = Double(second) + Double(frame) / sampleRate
                    let envelope = max(0, sin(time * 5.3) * sin(time * 1.7 + 0.4))
                    let tone = sin(2 * .pi * (220 + 180 * sin(time * 0.37 + sin(time * 0.013))) * time)
                    samples[frame] = Float(envelope * (0.5 * tone + 0.3 * noise))
                }
                try file.write(from: buffer)
            }
        }
    }
}
#endif
