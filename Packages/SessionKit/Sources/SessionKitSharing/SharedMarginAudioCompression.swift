import Foundation
import SessionKit
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Re-encodes one Margin's voice recording into a smaller `.m4a`. The packet builder never calls this itself: the
/// app compresses a prepared packet just before it is written (#3218), so the sender's stored recording is not touched.
public protocol SharedMarginAudioTranscoding: Sendable {
    /// Writes a re-encoded copy of `source` at `destination`. Throws when the copy can't be made.
    func transcode(_ source: URL, to destination: URL) async throws
}

/// What `SharedMarginAudioCompression.compressed` did, for the share screen and the diagnostics log.
public struct SharedMarginAudioCompressionReport: Equatable, Sendable {
    /// Voice assets whose file was replaced by a smaller copy.
    public var compressedCount = 0
    /// Voice assets sent as recorded because the copy was not smaller, or could not be made.
    public var keptOriginalCount = 0
    /// Voice assets that could not be re-encoded (a subset of `keptOriginalCount`).
    public var failedCount = 0
    public var originalBytes = 0
    public var sentBytes = 0

    public init() {}
}

/// Shared Margin audio goes out as HE-AAC mono at 24 kbps in an `.m4a` (the owner's pick after listening to his own
/// voice, 2026-11-02, #3218). The container, the `audio/mp4` type and the asset paths are the ones every shipped
/// build already accepts; only the bytes inside the file change.
public enum SharedMarginAudioCompression {
    public static let bitRate = 24_000
    /// HE-AAC's output rate; the encoder codes the lower half and rebuilds the top.
    public static let sampleRate = 44_100

    /// `prepared` with each Margin voice file (`originalVoice`, `cleanedVoice`) replaced by a re-encoded copy written
    /// into `folder`, when that copy is smaller. A file that can't be re-encoded, or comes out no smaller, goes out as it
    /// is: sharing never fails because of this step. Evidence assets, artifacts and the manifest descriptors are
    /// untouched (the archive writer records each file's size and digest from the file it reads).
    public static func compressed(
        _ prepared: PreparedSpokenMarginsPackage,
        workingIn folder: URL,
        using transcoder: any SharedMarginAudioTranscoding
    ) async -> (package: PreparedSpokenMarginsPackage, report: SharedMarginAudioCompressionReport) {
        var report = SharedMarginAudioCompressionReport()
        var assetFiles = prepared.assetFiles
        let voiceRoles: Set<String> = [SpokenMarginsAssetRole.originalVoice, SpokenMarginsAssetRole.cleanedVoice]
        let voicePaths = prepared.manifest.assets.filter { voiceRoles.contains($0.role) }.map(\.path)
        guard !voicePaths.isEmpty else { return (prepared, report) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, path) in voicePaths.enumerated() {
            guard let source = prepared.assetFiles[path] else { continue }
            let originalBytes = fileSize(of: source)
            report.originalBytes += originalBytes
            let destination = folder.appendingPathComponent(String(format: "margin-%04d.m4a", index + 1))
            try? FileManager.default.removeItem(at: destination)
            do {
                try await transcoder.transcode(source, to: destination)
                let reducedBytes = fileSize(of: destination)
                guard reducedBytes > 0, reducedBytes < originalBytes else {
                    try? FileManager.default.removeItem(at: destination)
                    report.keptOriginalCount += 1
                    report.sentBytes += originalBytes
                    continue
                }
                assetFiles[path] = destination
                report.compressedCount += 1
                report.sentBytes += reducedBytes
            } catch {
                try? FileManager.default.removeItem(at: destination)
                report.keptOriginalCount += 1
                report.failedCount += 1
                report.sentBytes += originalBytes
            }
        }
        return (
            PreparedSpokenMarginsPackage(manifest: prepared.manifest, artifactData: prepared.artifactData, assetFiles: assetFiles),
            report
        )
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }
}

#if canImport(AVFoundation)
public enum SharedMarginAudioTranscodingError: Error, Equatable {
    case unreadableSource
    case encoderUnavailable
    case conversionFailed(String)
}

/// Decodes the recording and encodes it again as HE-AAC mono at `SharedMarginAudioCompression.bitRate`. The work runs
/// on a background task: the caller awaits it and the main actor is free meanwhile.
public struct AVFoundationMarginAudioTranscoder: SharedMarginAudioTranscoding {
    public init() {}

    public func transcode(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.transcodeSynchronously(source, to: destination)
        }.value
    }

    private static let chunkFrames: AVAudioFrameCount = 16_384

    private static func transcodeSynchronously(_ source: URL, to destination: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw SharedMarginAudioTranscodingError.unreadableSource }
        guard input.length > 0, input.processingFormat.sampleRate > 0 else { throw SharedMarginAudioTranscodingError.unreadableSource }
        let output: AVAudioFile
        do {
            output = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC_HE),
                    AVSampleRateKey: SharedMarginAudioCompression.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: SharedMarginAudioCompression.bitRate
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw SharedMarginAudioTranscodingError.encoderUnavailable
        }
        let inputFormat = input.processingFormat
        let outputFormat = output.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
            throw SharedMarginAudioTranscodingError.encoderUnavailable
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(chunkFrames) * ratio) + 4_096
        ) else {
            throw SharedMarginAudioTranscodingError.encoderUnavailable
        }
        let feed = ConversionFeed(file: input, buffer: inputBuffer, chunkFrames: chunkFrames)
        var framesWritten: AVAudioFramePosition = 0
        while true {
            var failure: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &failure) { _, inputStatus in
                feed.next(inputStatus)
            }
            if status == .error {
                throw SharedMarginAudioTranscodingError.conversionFailed(failure?.localizedDescription ?? "unknown")
            }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
                framesWritten += AVAudioFramePosition(outputBuffer.frameLength)
            }
            if status == .endOfStream { break }
        }
        // A read that failed part-way would otherwise leave a short recording that looks smaller and valid.
        if let readFailure = feed.readFailure {
            throw SharedMarginAudioTranscodingError.conversionFailed(readFailure.localizedDescription)
        }
        // The manifest keeps the recording's length, so a copy that ended early is refused, not sent.
        let expectedSeconds = Double(input.length) / inputFormat.sampleRate
        let writtenSeconds = Double(framesWritten) / outputFormat.sampleRate
        guard abs(writtenSeconds - expectedSeconds) <= 0.5 else {
            throw SharedMarginAudioTranscodingError.conversionFailed("length \(writtenSeconds) s, expected \(expectedSeconds) s")
        }
    }

    /// Hands the converter the next chunk of the source file; one object so the converter's callback holds no
    /// mutable captured state.
    private final class ConversionFeed: @unchecked Sendable {
        private let file: AVAudioFile
        private let buffer: AVAudioPCMBuffer
        private let chunkFrames: AVAudioFrameCount
        private var finished = false
        private(set) var readFailure: (any Error)?

        init(file: AVAudioFile, buffer: AVAudioPCMBuffer, chunkFrames: AVAudioFrameCount) {
            self.file = file
            self.buffer = buffer
            self.chunkFrames = chunkFrames
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !finished else {
                status.pointee = .endOfStream
                return nil
            }
            buffer.frameLength = 0
            // Reading at the end of the file can throw on some systems instead of returning no frames.
            guard file.framePosition < file.length else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            do { try file.read(into: buffer, frameCount: chunkFrames) } catch {
                readFailure = error
                buffer.frameLength = 0
            }
            guard buffer.frameLength > 0 else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }
}
#endif
