import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation

/// Measures a Margin recording's loudness and writes a leveled copy for playback (#465).
///
/// The recording is only ever read: the copy goes to a URL the caller chooses, which must not be
/// the recording itself. The math is SessionKit's `LoudnessMeter` and `LoudnessLeveling`; this
/// type only decodes and writes files with AVFoundation, a chunk at a time (#731), so a Margin of
/// any length levels in the same small amount of memory.
public enum MarginLoudnessLeveler {
    public struct Result: Equatable, Sendable {
        public var input: LoudnessMeasurement
        public var plan: LoudnessLevelingPlan
        public var output: LoudnessMeasurement
    }

    public enum LevelerError: Error, Equatable {
        /// The copy would overwrite the recording.
        case destinationIsSource
        /// Only mono and stereo: BS.1770 weights other layouts by speaker (and leaves out the LFE),
        /// which a plain channel count can't tell.
        case unsupportedChannelCount(Int)
        case unreadable
    }

    /// Frames decoded, leveled and written at a time: about 1.5 s at 44.1 kHz. Working memory is a
    /// few copies of one chunk (a couple of MB for mono) plus about 30 numbers per second of audio
    /// for the measurement, however long the recording is.
    public static let defaultChunkFrames = 65_536

    /// Throws unless a recording with this many channels can be leveled.
    public static func checkCanLevel(channels: Int) throws {
        guard (1...2).contains(channels) else { throw LevelerError.unsupportedChannelCount(channels) }
    }

    public static func measure(fileAt url: URL, chunkFrames: Int = defaultChunkFrames) throws -> LoudnessMeasurement {
        let file = try openForReading(url)
        var meter = LoudnessMeter.Accumulator(channelCount: Int(file.processingFormat.channelCount), sampleRate: file.processingFormat.sampleRate)
        try forEachChunk(of: file, chunkFrames: chunkFrames) { meter.add($0) }
        return meter.finish()
    }

    /// Writes `source` leveled to `targetLUFS` as 32-bit float PCM at the source's sample rate and
    /// channel count. The destination's extension picks the container (.caf or .wav). The source is
    /// read twice, once to measure and once to render; the copy is written beside the destination
    /// first and moved into place, so a failed render never leaves half a file there.
    @discardableResult
    public static func renderLeveledCopy(
        of source: URL,
        to destination: URL,
        targetLUFS: Double = LoudnessLeveling.defaultTargetLUFS,
        chunkFrames: Int = defaultChunkFrames
    ) throws -> Result {
        guard !isSameFile(source, destination) else { throw LevelerError.destinationIsSource }
        let file = try openForReading(source)
        let sampleRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)

        var meter = LoudnessMeter.Accumulator(channelCount: channels, sampleRate: sampleRate)
        try forEachChunk(of: file, chunkFrames: chunkFrames) { meter.add($0) }
        let measured = meter.finish()
        let plan = LoudnessLeveling.plan(measured, targetLUFS: targetLUFS)

        var temporaries: [URL] = []
        defer { for url in temporaries { try? FileManager.default.removeItem(at: url) } }
        let leveled = temporaryURL(beside: destination)
        temporaries.append(leveled)
        var output = try writeChunks(to: leveled, sampleRate: sampleRate, channels: channels) { write -> LoudnessMeasurement in
            var renderer = LoudnessLeveling.Renderer(channelCount: channels, gainDB: plan.gainDB)
            var written = LoudnessMeter.Accumulator(channelCount: channels, sampleRate: sampleRate)
            try forEachChunk(of: file, chunkFrames: chunkFrames) { chunk in
                let out = renderer.process(chunk)
                written.add(out)
                try write(out)
            }
            let tail = renderer.finish()
            written.add(tail)
            try write(tail)
            return written.finish()
        }

        var finished = leveled
        // The limiter can leave a few hundredths of a dB over the ceiling, which only the whole
        // copy's true peak shows; when it does, a third pass turns the copy down to the ceiling.
        if let trim = LoudnessLeveling.ceilingTrim(forTruePeakDBTP: output.truePeakDBTP) {
            let trimmed = temporaryURL(beside: destination)
            temporaries.append(trimmed)
            output = try writeScaledCopy(of: leveled, by: trim, to: trimmed, chunkFrames: chunkFrames)
            finished = trimmed
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: finished)
        } else {
            try FileManager.default.moveItem(at: finished, to: destination)
        }
        return Result(input: measured, plan: plan, output: output)
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

    /// Writes `source` times `factor` to `destination` in the same format, and measures what it wrote.
    static func writeScaledCopy(of source: URL, by factor: Float, to destination: URL, chunkFrames: Int) throws -> LoudnessMeasurement {
        let file = try openForReading(source)
        let sampleRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        return try writeChunks(to: destination, sampleRate: sampleRate, channels: channels) { write -> LoudnessMeasurement in
            var written = LoudnessMeter.Accumulator(channelCount: channels, sampleRate: sampleRate)
            try forEachChunk(of: file, chunkFrames: chunkFrames) { chunk in
                let out = chunk.map { $0.map { $0 * factor } }
                written.add(out)
                try write(out)
            }
            return written.finish()
        }
    }

    static func openForReading(_ url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        try checkCanLevel(channels: Int(file.processingFormat.channelCount))
        return file
    }

    /// Hands `body` the file's samples from the start, `chunkFrames` frames at a time, one array
    /// per channel.
    static func forEachChunk(of file: AVAudioFile, chunkFrames: Int, _ body: ([[Float]]) throws -> Void) throws {
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(max(1, chunkFrames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw LevelerError.unreadable }
        file.framePosition = 0
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard let data = buffer.floatChannelData else { throw LevelerError.unreadable }
            try body((0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) })
        }
    }

    /// Opens `url` for writing 32-bit float PCM and lets `body` append chunks to it; the file is
    /// closed before this returns.
    static func writeChunks<T>(
        to url: URL,
        sampleRate: Double,
        channels: Int,
        _ body: (_ write: ([[Float]]) throws -> Void) throws -> T
    ) throws -> T {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: false
        ) else {
            throw LevelerError.unreadable
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
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { file.close() }
        return try body { chunk in
            let frames = chunk.first?.count ?? 0
            guard frames > 0 else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else {
                throw LevelerError.unreadable
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            for (index, channel) in chunk.enumerated() {
                channel.withUnsafeBufferPointer { samples in
                    if let base = samples.baseAddress { data[index].update(from: base, count: frames) }
                }
            }
            try file.write(from: buffer)
        }
    }

    /// A hidden file beside `destination`, with its name and so its extension (which picks the
    /// container) at the end.
    static func temporaryURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".leveling-\(UUID().uuidString)-\(destination.lastPathComponent)")
    }
}
#endif
