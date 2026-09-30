import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation

/// Measures a Margin recording's loudness and writes a leveled copy for playback (#465).
///
/// The recording is only ever read: the copy goes to a URL the caller chooses, which must not be
/// the recording itself. The math is SessionKit's `LoudnessMeter` and `LoudnessLeveling`; this
/// type only decodes and writes files with AVFoundation.
public enum MarginLoudnessLeveler {
    public struct Result: Equatable, Sendable {
        public var input: LoudnessMeasurement
        public var plan: LoudnessLevelingPlan
        public var output: LoudnessMeasurement
    }

    public enum LevelerError: Error, Equatable {
        /// The copy would overwrite the recording.
        case destinationIsSource
        case tooLong(seconds: Double)
        case unreadable
    }

    /// Margins are a few minutes at most. Measuring and rendering hold several full-length copies
    /// of the samples, so this keeps a stray long file from using hundreds of MB.
    public static let maximumSeconds = 10.0 * 60

    public static func measure(fileAt url: URL) throws -> LoudnessMeasurement {
        let decoded = try read(url)
        return LoudnessMeter.measure(channels: decoded.channels, sampleRate: decoded.sampleRate)
    }

    /// Writes `source` leveled to `targetLUFS` as 32-bit float PCM at the source's sample rate and
    /// channel count. The destination's extension picks the container (.caf or .wav). The
    /// copy is written beside the destination first and moved into place, so a failed render never
    /// leaves half a file there.
    @discardableResult
    public static func renderLeveledCopy(
        of source: URL,
        to destination: URL,
        targetLUFS: Double = LoudnessLeveling.defaultTargetLUFS
    ) throws -> Result {
        guard !isSameFile(source, destination) else { throw LevelerError.destinationIsSource }
        let decoded = try read(source)
        let measured = LoudnessMeter.measure(channels: decoded.channels, sampleRate: decoded.sampleRate)
        let plan = LoudnessLeveling.plan(measured, targetLUFS: targetLUFS)
        let leveled = LoudnessLeveling.render(channels: decoded.channels, gainDB: plan.gainDB)
        try write(leveled, sampleRate: decoded.sampleRate, to: destination)
        return Result(
            input: measured,
            plan: plan,
            output: LoudnessMeter.measure(channels: leveled, sampleRate: decoded.sampleRate)
        )
    }

    /// Same path, or (on a case-insensitive disk, or through another link) the same file on disk.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let first = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let second = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return first.isEqual(second)
    }

    static func read(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        guard seconds <= maximumSeconds else { throw LevelerError.tooLong(seconds: seconds) }
        guard file.length > 0 else { return (Array(repeating: [], count: Int(format.channelCount)), format.sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LevelerError.unreadable
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw LevelerError.unreadable }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
        return (channels, format.sampleRate)
    }

    static func write(_ channels: [[Float]], sampleRate: Double, to destination: URL) throws {
        let frames = channels.first?.count ?? 0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(max(1, channels.count)), interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))),
              let data = buffer.floatChannelData else {
            throw LevelerError.unreadable
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { samples in
                if let base = samples.baseAddress { data[index].update(from: base, count: frames) }
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".leveling-\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if frames > 0 { try file.write(from: buffer) }
            file.close()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
#endif
