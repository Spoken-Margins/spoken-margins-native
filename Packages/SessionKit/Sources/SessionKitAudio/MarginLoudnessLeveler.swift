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
        /// Leveling would need more working memory than `maximumWorkingBytes`.
        case tooLarge(estimatedBytes: Int64)
        /// Only mono and stereo: BS.1770 weights other layouts by speaker (and leaves out the LFE),
        /// which a plain channel count can't tell.
        case unsupportedChannelCount(Int)
        case unreadable
    }

    /// Measuring and rendering hold the whole recording several times over: the decoded and leveled
    /// samples as Float, and the K-weighted signal, oversampled peaks and limiter gains as Double.
    /// `estimatedWorkingBytes` counts that generously, and anything over this budget is refused
    /// before a sample is decoded. A mono Margin at 44.1 kHz fits about 3 minutes.
    public static let maximumWorkingBytes: Int64 = 512 * 1024 * 1024

    /// About 48 bytes per frame for the Double working arrays, plus 16 per channel for the Float
    /// copies and the per-channel K-weighted and oversampled arrays.
    public static func estimatedWorkingBytes(frames: Int64, channels: Int) -> Int64 {
        let (bytes, overflow) = frames.multipliedReportingOverflow(by: 48 + 16 * Int64(max(1, channels)))
        return overflow ? .max : bytes
    }

    /// Throws unless a recording of this shape can be leveled; called before anything is allocated.
    public static func checkCanLevel(frames: Int64, channels: Int) throws {
        guard (1...2).contains(channels) else { throw LevelerError.unsupportedChannelCount(channels) }
        let bytes = estimatedWorkingBytes(frames: frames, channels: channels)
        guard bytes <= maximumWorkingBytes else { throw LevelerError.tooLarge(estimatedBytes: bytes) }
    }

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
        try checkCanLevel(frames: file.length, channels: Int(format.channelCount))
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
