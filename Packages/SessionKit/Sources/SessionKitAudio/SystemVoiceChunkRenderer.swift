#if canImport(AVFoundation)
import AVFoundation
import Foundation
import SessionKit

/// Reads one narration chunk with the iOS voice into a file in the same audio format as a
/// Supertonic chunk, so playback and prepared-audio assembly treat it like any other chunk.
/// Used when a Supertonic chunk fails `SupertonicOutputCheck` (#240): the iOS voice reads numbers
/// and symbols as words, where Supertonic babbles.
public final class SystemVoiceChunkRenderer: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case emptyText
        case noAudio
        case timedOut
    }

    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private let usesApplicationAudioSession: Bool

    /// Rendering to a file needs no audio output. By default a speech synthesizer shares the app's
    /// audio session, and rendering while Supertonic plays can disturb that session: the player
    /// went silent while reporting "playing" until the output route changed (#288). So this
    /// renderer keeps the synthesizer off the app's session.
    public init(usesApplicationAudioSession: Bool = false) {
        self.usesApplicationAudioSession = usesApplicationAudioSession
    }

    /// Writes `text` to `outputURL` in `reference`'s file format and returns its duration in seconds.
    public func render(
        text: String,
        voiceIdentifier: String?,
        matching reference: URL,
        to outputURL: URL,
        timeout: TimeInterval = 30
    ) async throws -> TimeInterval {
        let speech = SpeechTextNormalizer.projectForSystemSpeech(text).text
        guard !speech.isEmpty, SpeechTextNormalizer.isSystemSpeechSafe(speech) else { throw Failure.emptyText }
        let referenceFile = try AVAudioFile(forReading: reference)
        let format = referenceFile.processingFormat
        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: referenceFile.fileFormat.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let utterance = AVSpeechUtterance(string: speech)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        let writer = ConvertingWriter(output: output, format: format)
        let synthesizer = AVSpeechSynthesizer()
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = usesApplicationAudioSession
        #endif
        lock.withLock { self.synthesizer = synthesizer }
        defer { lock.withLock { self.synthesizer = nil } }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: Failure.timedOut)
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    do {
                        try writer.finish()
                        once.resume()
                    } catch {
                        once.resume(throwing: error)
                    }
                    return
                }
                do { try writer.append(pcm) } catch { once.resume(throwing: error) }
            }
        }
        guard writer.framesWritten > 0 else { throw Failure.noAudio }
        return Double(writer.framesWritten) / format.sampleRate
    }
}

/// Converts the synthesizer's buffers (often 22.05 kHz) to the target format as they arrive.
private final class ConvertingWriter: @unchecked Sendable {
    private let output: AVAudioFile
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(output: AVAudioFile, format: AVAudioFormat) {
        self.output = output
        self.format = format
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
        try convert(buffer, endOfStream: false)
    }

    func finish() throws {
        if converter != nil { try convert(nil, endOfStream: true) }
        // The synthesizer can outlive this call; close now so the file is complete when read.
        output.close()
    }

    private func convert(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) throws {
        guard let converter else { return }
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer?.frameLength ?? 4_096) * ratio) + 1_024
        var supplied = false
        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if let buffer, !supplied {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let conversionError { throw conversionError }
            if converted.frameLength > 0 {
                try output.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            }
            if status != .haveData { return }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume(throwing error: Error? = nil) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
#endif
