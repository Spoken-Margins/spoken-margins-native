import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

/// One "is this quiet?" flag per 20 ms of a spoken-note take (#4779), for `SpokenNoteTakeCut.make`.
///
/// It uses the same RMS windowing and adaptive noise floor as `InterjectionSilenceDetector` (the share review's
/// pause finder): a window is quiet when its level is at or below the 20th-percentile level plus 8 dB, clamped to
/// -50...-32 dBFS. Unlike that detector it applies no transcript mask: the cut decides what to do with words.
public enum SpokenNoteSilentFlags {
    public static let windowMs = InterjectionSilenceDetector.analysisWindowMs

    public struct Result: Equatable, Sendable {
        public var flags: [Bool]
        public var durationMs: Int
        public init(flags: [Bool], durationMs: Int) {
            self.flags = flags
            self.durationMs = durationMs
        }
    }

    /// The threshold rule on its own, so it can be checked without audio.
    public static func flags(levelsDB: [Double]) -> [Bool] {
        guard !levelsDB.isEmpty else { return [] }
        let sorted = levelsDB.sorted()
        let noiseIndex = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.20).rounded()))
        let threshold = min(-32, max(-50, sorted[noiseIndex] + 8))
        return levelsDB.map { $0 <= threshold }
    }

    #if canImport(AVFoundation)
    /// Reads the file once, streaming, so a two-hour take holds only its window levels (360,000 Doubles) in memory.
    public static func read(url: URL) throws -> Result {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(4_096, Int(sampleRate)))) else {
            throw SessionKitError.persistenceFailed("spoken_note_silent_flags_format_invalid")
        }
        let framesPerWindow = max(1, Int((sampleRate * Double(windowMs) / 1_000).rounded()))
        var levels: [Double] = []
        levels.reserveCapacity(Int(Double(file.length) / Double(framesPerWindow)) + 1)
        var square = 0.0
        var frames = 0
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var frameSquare = 0.0
                for channel in 0..<channelCount {
                    let sample = Double(channels[channel][frame])
                    frameSquare += sample * sample
                }
                square += frameSquare / Double(channelCount)
                frames += 1
                if frames == framesPerWindow {
                    levels.append(10 * log10(max(1e-12, square / Double(frames))))
                    square = 0
                    frames = 0
                }
            }
        }
        if frames > 0 { levels.append(10 * log10(max(1e-12, square / Double(frames)))) }
        let durationMs = Int((Double(file.length) / sampleRate * 1_000).rounded())
        return Result(flags: flags(levelsDB: levels), durationMs: durationMs)
    }
    #endif
}
