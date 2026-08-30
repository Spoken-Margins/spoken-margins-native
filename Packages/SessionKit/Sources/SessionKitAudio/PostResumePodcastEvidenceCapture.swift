import Foundation
import SessionKit

#if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import MediaToolbox
import ShazamKit

public struct CapturedPostResumePodcastEvidence: Sendable {
    public let request: PostResumeAudioSampleRequest
    public let signatureData: Data
    public let durationMs: Int
    public let anchorOffsetMs: Int

    public init(
        request: PostResumeAudioSampleRequest,
        signatureData: Data,
        durationMs: Int,
        anchorOffsetMs: Int
    ) {
        self.request = request
        self.signatureData = signatureData
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
    }
}

public enum PostResumePodcastEvidenceCaptureResult: Sendable {
    case captured(CapturedPostResumePodcastEvidence)
    case failed(request: PostResumeAudioSampleRequest, reason: String)
}

/// Owns the short-lived state behind one AVPlayer audio tap. It is armed only
/// after a Margin is recorded and releases each signature generator as soon as
/// its bounded post-resume sample is complete. Multiple closely spaced Margins
/// share this tap and receive the same decoded playback buffers independently.
final class PostResumePodcastEvidenceTapContext: @unchecked Sendable {
    typealias ResultHandler = @Sendable (PostResumePodcastEvidenceCaptureResult) -> Void

    private final class Accumulator: @unchecked Sendable {
        let request: PostResumeAudioSampleRequest
        let generator = SHSignatureGenerator()
        var appendedFrames: Int64 = 0
        var firstMediaTimeMs: Int?

        init(request: PostResumeAudioSampleRequest) {
            self.request = request
        }
    }

    private let lock = NSLock()
    private let completionQueue = DispatchQueue(
        label: "com.spokenmargins.podcast-post-resume-evidence",
        qos: .utility
    )
    private let resultHandler: ResultHandler
    private let becameIdle: @Sendable () -> Void
    private var format: AVAudioFormat?
    private var accumulators: [String: Accumulator] = [:]

    init(
        resultHandler: @escaping ResultHandler,
        becameIdle: @escaping @Sendable () -> Void
    ) {
        self.resultHandler = resultHandler
        self.becameIdle = becameIdle
    }

    func arm(_ request: PostResumeAudioSampleRequest) -> Bool {
        guard request.targetDurationMs >= PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs else {
            return false
        }
        let armed = lock.withLock {
            guard accumulators[request.interjectionId] == nil else { return false }
            accumulators[request.interjectionId] = Accumulator(request: request)
            return true
        }
        if armed {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.failIfPending(
                    interjectionId: request.interjectionId,
                    reason: "decoded_playback_sample_timed_out"
                )
            }
        }
        return armed
    }

    func prepare(processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
        lock.withLock {
            format = AVAudioFormat(streamDescription: processingFormat)
        }
    }

    func unprepare() {
        lock.withLock {
            format = nil
        }
    }

    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: CMItemCount,
        timeRange: CMTimeRange,
        endOfStream: Bool = false
    ) {
        guard frameCount > 0 else { return }
        var completed: [Accumulator] = []
        var failed: [(Accumulator, String)] = []
        let becameEmpty = lock.withLock { () -> Bool in
            guard let format,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: bufferList,
                    deallocator: nil
                  ) else {
                failed = accumulators.values.map { ($0, "decoded_playback_buffer_invalid") }
                accumulators.removeAll()
                return !failed.isEmpty
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let mediaTimeMs = Self.mediaTimeMs(timeRange.start)
            for (id, accumulator) in accumulators {
                do {
                    if accumulator.firstMediaTimeMs == nil {
                        accumulator.firstMediaTimeMs = mediaTimeMs
                    }
                    try accumulator.generator.append(buffer, at: nil)
                    accumulator.appendedFrames += Int64(frameCount)
                    let targetFrames = Int64(
                        (Double(accumulator.request.targetDurationMs) * format.sampleRate / 1_000).rounded(.up)
                    )
                    let minimumFrames = Int64(
                        (Double(PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs)
                            * format.sampleRate / 1_000).rounded(.up)
                    )
                    if accumulator.appendedFrames >= targetFrames
                        || (endOfStream && accumulator.appendedFrames >= minimumFrames) {
                        completed.append(accumulator)
                        accumulators[id] = nil
                    } else if endOfStream {
                        failed.append((accumulator, "insufficient_post_resume_audio"))
                        accumulators[id] = nil
                    }
                } catch {
                    failed.append((accumulator, "signature_append_failed:\(error.localizedDescription)"))
                    accumulators[id] = nil
                }
            }
            return accumulators.isEmpty && (!completed.isEmpty || !failed.isEmpty)
        }

        for accumulator in completed {
            finish(accumulator)
        }
        for (accumulator, reason) in failed {
            resultHandler(.failed(request: accumulator.request, reason: reason))
        }
        if becameEmpty {
            becameIdle()
        }
    }

    func cancelAll(reason: String) {
        let cancelled = lock.withLock { () -> [Accumulator] in
            let values = Array(accumulators.values)
            accumulators.removeAll()
            return values
        }
        for accumulator in cancelled {
            resultHandler(.failed(request: accumulator.request, reason: reason))
        }
    }

    private func failIfPending(interjectionId: String, reason: String) {
        let failed = lock.withLock { accumulators.removeValue(forKey: interjectionId) }
        guard let failed else { return }
        resultHandler(.failed(request: failed.request, reason: reason))
        if lock.withLock({ accumulators.isEmpty }) {
            becameIdle()
        }
    }

    private func finish(_ accumulator: Accumulator) {
        completionQueue.async { [resultHandler] in
            let signature = accumulator.generator.signature()
            let data = signature.dataRepresentation
            guard !data.isEmpty else {
                resultHandler(.failed(
                    request: accumulator.request,
                    reason: "signature_generation_failed"
                ))
                return
            }
            guard let firstMediaTimeMs = accumulator.firstMediaTimeMs else {
                resultHandler(.failed(
                    request: accumulator.request,
                    reason: "decoded_playback_time_unavailable"
                ))
                return
            }
            resultHandler(.captured(CapturedPostResumePodcastEvidence(
                request: accumulator.request,
                signatureData: data,
                durationMs: max(1, Int((signature.duration * 1_000).rounded())),
                anchorOffsetMs: accumulator.request.anchorMediaTimeMs - firstMediaTimeMs
            )))
        }
    }

    private static func mediaTimeMs(_ time: CMTime) -> Int? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int((seconds * 1_000).rounded())
    }
}

enum PostResumePodcastEvidenceTapFactory {
    static func make(context tapContext: PostResumePodcastEvidenceTapContext) throws -> MTAudioProcessingTap {
        let retainedContext = Unmanaged.passRetained(tapContext)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedContext.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<PostResumePodcastEvidenceTapContext>.fromOpaque(storage).release()
            },
            prepare: { tap, _, processingFormat in
                PostResumePodcastEvidenceTapFactory.storedContext(for: tap)
                    .prepare(processingFormat: processingFormat)
            },
            unprepare: { tap in
                PostResumePodcastEvidenceTapFactory.storedContext(for: tap).unprepare()
            },
            process: { tap, requestedFrames, _, bufferList, framesOut, flagsOut in
                var sourceFlags = MTAudioProcessingTapFlags()
                var sourceTimeRange = CMTimeRange.invalid
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    requestedFrames,
                    bufferList,
                    &sourceFlags,
                    &sourceTimeRange,
                    &sourceFrames
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    flagsOut.pointee = sourceFlags
                    return
                }
                framesOut.pointee = sourceFrames
                flagsOut.pointee = sourceFlags
                PostResumePodcastEvidenceTapFactory.storedContext(for: tap).process(
                    bufferList: bufferList,
                    frameCount: sourceFrames,
                    timeRange: sourceTimeRange,
                    endOfStream: sourceFlags
                        & MTAudioProcessingTapFlags(kMTAudioProcessingTapFlag_EndOfStream) != 0
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects),
            &tap
        )
        guard status == noErr, let tap else {
            retainedContext.release()
            throw SessionKitError.persistenceFailed("decoded_playback_tap_create_failed:\(status)")
        }
        return tap
    }

    private static func storedContext(
        for tap: MTAudioProcessingTap
    ) -> PostResumePodcastEvidenceTapContext {
        Unmanaged<PostResumePodcastEvidenceTapContext>
            .fromOpaque(MTAudioProcessingTapGetStorage(tap))
            .takeUnretainedValue()
    }
}
#endif
