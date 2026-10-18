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

    /// Starts a write on `synthesizer`, delivering its buffers to the callback. The real one is
    /// `AVSpeechSynthesizer.write`; tests pass one that stalls or sends late buffers.
    typealias SpeechWrite = @Sendable (AVSpeechSynthesizer, AVSpeechUtterance, @escaping @Sendable (AVAudioBuffer) -> Void) -> Void
    /// Finds the voice for an identifier. The real one is `AVSpeechSynthesisVoice(identifier:)`,
    /// which blocks on the same TextToSpeech semaphore as the write while the speech service starts.
    typealias VoiceLookup = @Sendable (String) -> AVSpeechSynthesisVoice?

    /// `AVSpeechSynthesizer.write` can block its caller for minutes, on a semaphore inside Apple's
    /// TextToSpeech while the speech service loads (#1230). It is called here, never on a Swift
    /// concurrency thread, so the render's timeout still fires and the app's task threads stay free.
    /// Serial, so a stuck write holds back later writes rather than piling up blocked threads.
    fileprivate static let writeQueue = DispatchQueue(label: "SessionKitAudio.SystemVoiceChunkRenderer.write", qos: .userInitiated)

    private let usesApplicationAudioSession: Bool
    private let speechWrite: SpeechWrite
    private let voiceLookup: VoiceLookup
    private let releaseDelay: TimeInterval

    /// Rendering to a file needs no audio output. By default a speech synthesizer shares the app's
    /// audio session, and rendering while Supertonic plays can disturb that session: the player
    /// went silent while reporting "playing" until the output route changed (#288). So this
    /// renderer keeps the synthesizer off the app's session.
    public convenience init(usesApplicationAudioSession: Bool = false) {
        self.init(usesApplicationAudioSession: usesApplicationAudioSession, releaseDelay: 1) { synthesizer, utterance, callback in
            synthesizer.write(utterance) { callback($0) }
        }
    }

    init(
        usesApplicationAudioSession: Bool,
        releaseDelay: TimeInterval,
        voiceLookup: @escaping VoiceLookup = { AVSpeechSynthesisVoice(identifier: $0) },
        speechWrite: @escaping SpeechWrite
    ) {
        self.usesApplicationAudioSession = usesApplicationAudioSession
        self.releaseDelay = releaseDelay
        self.voiceLookup = voiceLookup
        self.speechWrite = speechWrite
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
        let synthesizer = AVSpeechSynthesizer()
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = usesApplicationAudioSession
        #endif
        let job = SpeechWriteJob(
            synthesizer: synthesizer, utterance: utterance,
            writer: ConvertingWriter(output: output, format: format),
            releaseDelay: releaseDelay, settleDelay: timeout + 300
        )
        let speechWrite = self.speechWrite
        let voiceLookup = self.voiceLookup
        let framesWritten = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioFramePosition, Error>) in
            job.onEnd = { continuation.resume(with: $0) }
            // Weak: a job is let go only after its stream has ended, so a gone job needs no timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak job] in job?.timeOut() }
            // The voice is looked up on the write queue too: on a speech service still starting, the
            // lookup blocked its caller with no limit, before the timeout above was set (#1688).
            Self.writeQueue.async { job.start(voiceIdentifier: voiceIdentifier, voiceLookup: voiceLookup, speechWrite) }
        }
        guard framesWritten > 0 else { throw Failure.noAudio }
        return Double(framesWritten) / format.sampleRate
    }
}

/// One write from start to the synthesizer's own finish. The render returns at the first
/// end-of-stream buffer, but the synthesizer goes on: it sends a second empty buffer and then
/// `didFinish` on the main queue (seen on macOS 26). Releasing the synthesizer as the render
/// returned crashed the app inside TextToSpeech, in a main-queue block, at 0x10 (#1230, #768).
/// So the job keeps itself and its synthesizer alive until `didFinish` or `didCancel` arrives,
/// then lets go a moment later on the main queue. Anything the synthesizer sends after the end
/// of the stream or after a timeout is ignored.
private final class SpeechWriteJob: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: SpeechWriteJob] = [:]

    private let lock = NSLock()
    private let synthesizer: AVSpeechSynthesizer
    private let utterance: AVSpeechUtterance
    private let writer: ConvertingWriter
    private let releaseDelay: TimeInterval
    private let settleDelay: TimeInterval
    private var ended = false
    private var retiring = false
    /// Set before the job starts; called once, with the frames written or the error.
    var onEnd: ((Result<AVAudioFramePosition, Error>) -> Void)?

    init(synthesizer: AVSpeechSynthesizer, utterance: AVSpeechUtterance, writer: ConvertingWriter,
         releaseDelay: TimeInterval, settleDelay: TimeInterval) {
        self.synthesizer = synthesizer
        self.utterance = utterance
        self.writer = writer
        self.releaseDelay = releaseDelay
        self.settleDelay = settleDelay
        super.init()
        synthesizer.delegate = self
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = self }
    }

    /// Runs on the write queue. The write may block here for a long time.
    func start(
        voiceIdentifier: String?,
        voiceLookup: SystemVoiceChunkRenderer.VoiceLookup,
        _ speechWrite: SystemVoiceChunkRenderer.SpeechWrite
    ) {
        if lock.withLock({ ended }) {
            // Timed out before its turn: nothing was asked of the synthesizer, so nothing is in flight.
            retire()
            return
        }
        if let voiceIdentifier {
            if let voice = voiceLookup(voiceIdentifier) { utterance.voice = voice }
            // The lookup can block for minutes; if the render timed out meanwhile, don't write.
            if lock.withLock({ ended }) {
                retire()
                return
            }
        }
        speechWrite(synthesizer, utterance) { [weak self] buffer in self?.receive(buffer) }
        // If neither `didFinish` nor `didCancel` ever comes, let go long after the render has ended:
        // holding one idle synthesizer for minutes is cheap, releasing a busy one crashed the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in self?.retire() }
    }

    private func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            endStream()
            return
        }
        let failure: Error? = lock.withLock {
            guard !ended else { return nil }
            do {
                try writer.append(pcm)
                return nil
            } catch {
                ended = true
                writer.close()
                return error
            }
        }
        if let failure { end(.failure(failure)) }
    }

    /// The first empty buffer ends the stream; so does `didFinish` or `didCancel` if it comes first.
    private func endStream() {
        let outcome: Result<AVAudioFramePosition, Error>? = lock.withLock {
            guard !ended else { return nil }
            ended = true
            do {
                try writer.finish()
                return .success(writer.framesWritten)
            } catch {
                writer.close()
                return .failure(error)
            }
        }
        if let outcome { end(outcome) }
    }

    func timeOut() {
        let timedOut: Bool = lock.withLock {
            guard !ended else { return false }
            ended = true
            writer.close()
            return true
        }
        guard timedOut else { return }
        end(.failure(SystemVoiceChunkRenderer.Failure.timedOut))
        // Queued behind the write, so it reaches the synthesizer only once the write has returned.
        SystemVoiceChunkRenderer.writeQueue.async { [self] in _ = synthesizer.stopSpeaking(at: .immediate) }
    }

    private func end(_ outcome: Result<AVAudioFramePosition, Error>) {
        let handler = lock.withLock { () -> ((Result<AVAudioFramePosition, Error>) -> Void)? in
            defer { onEnd = nil }
            return onEnd
        }
        handler?(outcome)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        endStream()
        retire()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        endStream()
        retire()
    }

    /// Lets go of the job and its synthesizer after `releaseDelay`, on the main queue, so any block
    /// the synthesizer queued there before finishing has run.
    private func retire() {
        let first = lock.withLock { () -> Bool in
            defer { retiring = true }
            return !retiring
        }
        guard first else { return }
        let key = ObjectIdentifier(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseDelay) {
            let job = Self.liveLock.withLock { Self.live.removeValue(forKey: key) }
            withExtendedLifetime(job) {}
        }
    }

    static var liveCount: Int { liveLock.withLock { live.count } }
}

extension SystemVoiceChunkRenderer {
    /// Writes still held until their synthesizer finishes. For tests.
    static var heldWriteCount: Int { SpeechWriteJob.liveCount }
}

/// Converts the synthesizer's buffers (often 22.05 kHz) to the target format as they arrive.
/// After `finish()` or `close()` it ignores anything more, so nothing reaches a closed file.
private final class ConvertingWriter: @unchecked Sendable {
    private let output: AVAudioFile
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var closed = false
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(output: AVAudioFile, format: AVAudioFormat) {
        self.output = output
        self.format = format
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard !closed else { return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
        try convert(buffer, endOfStream: false)
    }

    func finish() throws {
        guard !closed else { return }
        defer { close() }
        if converter != nil { try convert(nil, endOfStream: true) }
    }

    /// Closes the file now, so it is complete when read, whatever the synthesizer does next.
    func close() {
        guard !closed else { return }
        closed = true
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
#endif
