import Foundation
import SessionKit

#if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import MediaToolbox
import ShazamKit

public struct CapturedPostResumePodcastEvidence: Sendable {
    public enum WindowRole: String, Sendable {
        case preInterjection = "pre_interjection"
        case postResume = "post_resume"
    }

    public let request: PostResumeAudioSampleRequest
    public let signatureData: Data
    public let durationMs: Int
    public let anchorOffsetMs: Int
    public let windowRole: WindowRole
    public let provenance: EpisodeFingerprintProvenance

    public init(
        request: PostResumeAudioSampleRequest,
        signatureData: Data,
        durationMs: Int,
        anchorOffsetMs: Int,
        windowRole: WindowRole = .postResume,
        provenance: EpisodeFingerprintProvenance = .observedDecodedPlayback
    ) {
        self.request = request
        self.signatureData = signatureData
        self.durationMs = durationMs
        self.anchorOffsetMs = anchorOffsetMs
        self.windowRole = windowRole
        self.provenance = provenance
    }
}

public struct CapturedEpisodeFingerprintLandmark: Sendable {
    public let itemId: String
    public let sourceMediaStartMs: Int
    public let sourceMediaEndMs: Int
    public let anchorMediaTimeMs: Int
    public let continuityEpoch: Int
    public let gridIndex: Int?
    public let trigger: EpisodeFingerprintTrigger
    public let signatureData: Data
    public let durationMs: Int
}

public enum PostResumePodcastEvidenceCaptureResult: Sendable {
    case captured(CapturedPostResumePodcastEvidence)
    case landmark(CapturedEpisodeFingerprintLandmark)
    case failed(request: PostResumeAudioSampleRequest, reason: String)
}

/// Owns the short-lived state behind one AVPlayer audio tap. It is armed only
/// after a Margin is recorded and releases each signature generator as soon as
/// its bounded post-resume sample is complete. Multiple closely spaced Margins
/// share this tap and receive the same decoded playback buffers independently.
///
/// The tap's `process` callback runs on the real-time audio thread (#457). It only copies the decoded buffer and
/// hands the copy to a serial worker queue; the ring, the heard-audio recorder and every signature append run on
/// that queue. The audio thread never takes `lock`, which the worker holds while it appends, so slow signature
/// work can't stall playback. The worker takes buffers in order, and the methods that read or change capture
/// state from outside (`captureBufferedPreInterjection`, `noteSeek`, `cancelAll`) wait for the buffers already
/// handed over first, so they see them.
final class PostResumePodcastEvidenceTapContext: @unchecked Sendable {
    typealias ResultHandler = @Sendable (PostResumePodcastEvidenceCaptureResult) -> Void
    typealias HeardWindowHandler = @Sendable (HeardAudioWindow) -> Void
    typealias SignatureAppend = @Sendable (SHSignatureGenerator, AVAudioPCMBuffer) throws -> Void

    private final class Accumulator: @unchecked Sendable {
        let request: PostResumeAudioSampleRequest
        var generator = SHSignatureGenerator()
        var appendedFrames: Int64 = 0
        var skippedFrames: Int64 = 0
        var firstMediaTimeMs: Int?
        /// The end of the last decoded buffer this window saw, to notice playback moving back.
        var lastBufferEndMs: Int?

        init(request: PostResumeAudioSampleRequest) {
            self.request = request
        }

        /// Starts the window again, capture delay included, as after a seek.
        func restart() {
            generator = SHSignatureGenerator()
            appendedFrames = 0
            skippedFrames = 0
            firstMediaTimeMs = nil
            lastBufferEndMs = nil
        }
    }

    struct RingChunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let startMediaTimeMs: Int
        let endMediaTimeMs: Int
    }

    /// One decoded buffer the tap copied for the worker, with what the worker needs to place it.
    private struct TapWork: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let mediaTimeMs: Int?
        let endOfStream: Bool
        /// Buffers were dropped just before this one (the worker fell too far behind), so the audio isn't contiguous.
        let gapBefore: Bool
    }

    /// What the audio thread learned from `tapLock` about one buffer it may copy.
    private struct Admission: @unchecked Sendable {
        let format: AVAudioFormat
        let gapBefore: Bool
    }

    /// Rounding slack when deciding whether a buffer starts before the audio already seen ends.
    static let rewindToleranceMs = 10
    /// The most a buffer may start after the previous one ended before the ring counts a hole there. Start and end
    /// times are each rounded to a millisecond, so adjacent buffers differ by a couple at most.
    static let contiguityToleranceMs = 25
    /// The most decoded audio the tap keeps waiting for the worker. Beyond it the tap drops buffers, and the
    /// windows start again after the gap, rather than letting memory grow behind a stuck worker.
    static let maxPendingSeconds = 20.0

    private let lock = NSLock()
    /// Guards only what the audio thread touches (`tapFormat`, `pendingFrames`, `droppedWhilePending`), and is
    /// never held for more than a few instructions.
    private let tapLock = NSLock()
    private let workQueue = DispatchQueue(
        label: "com.spokenmargins.podcast-evidence-work",
        qos: .userInitiated
    )
    private let completionQueue = DispatchQueue(
        label: "com.spokenmargins.podcast-post-resume-evidence",
        qos: .utility
    )
    private let resultHandler: ResultHandler
    private let becameIdle: @Sendable () -> Void
    private let continuousCollection: Bool
    private let itemId: String?
    private var format: AVAudioFormat?
    private var accumulators: [String: Accumulator] = [:]
    private var ring: [RingChunk] = []
    private var sparseSchedule = SparseFingerprintSchedule()
    private var pendingStablePostSeekStartMs: Int?
    /// The newest seek epoch whose one stable-post-seek landmark was cut. Without it the branch below refilled
    /// `pendingStablePostSeekStartMs` from the ring on every buffer and cut a landmark again and again (#2626).
    private var stablePostSeekServedEpoch = 0
    private var generatingLandmarkKeys: Set<String> = []
    /// The minute before and after each Margin, as heard, for source-context transcription (#156).
    private var heardRecorder: HeardAudioWindowRecorder?
    private var heardDownsampleFactor = 1
    private let heardWindowHandler: HeardWindowHandler?
    private let appendToSignature: SignatureAppend
    private var tapFormat: AVAudioFormat?
    private var pendingFrames = 0
    private var droppedWhilePending = false
    private var latestDecoded: DecodedAudioClockGuard.DecodedSample?

    /// Where the latest decoded buffer ends in the source, and when the tap saw it: evidence of the audio
    /// actually being rendered, independent of the player's clock (#2094).
    var latestDecodedSample: DecodedAudioClockGuard.DecodedSample? { tapLock.withLock { latestDecoded } }

    var retainsContinuousCollection: Bool { continuousCollection }

    /// Decoded frames the tap has handed over that the worker hasn't finished with.
    var pendingTapFrames: Int { tapLock.withLock { pendingFrames } }

    init(
        resultHandler: @escaping ResultHandler,
        becameIdle: @escaping @Sendable () -> Void,
        continuousCollection: Bool = false,
        itemId: String? = nil,
        heardWindowHandler: HeardWindowHandler? = nil,
        appendToSignature: @escaping SignatureAppend = { try $0.append($1, at: nil) }
    ) {
        self.resultHandler = resultHandler
        self.becameIdle = becameIdle
        self.continuousCollection = continuousCollection
        self.itemId = itemId
        self.heardWindowHandler = heardWindowHandler
        self.appendToSignature = appendToSignature
    }

    /// Waits for the buffers the tap has already handed to the worker.
    private func drainTapWork() {
        workQueue.sync {}
    }

    /// Reports a failure from the worker's side: results go out on the completion queue, like the others.
    private func report(_ result: PostResumePodcastEvidenceCaptureResult) {
        completionQueue.async { [resultHandler] in resultHandler(result) }
    }

    private func deliver(_ windows: [HeardAudioWindow]) {
        guard !windows.isEmpty, let heardWindowHandler else { return }
        completionQueue.async { windows.forEach(heardWindowHandler) }
    }

    func arm(_ request: PostResumeAudioSampleRequest) -> Bool {
        guard request.targetDurationMs >= PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs else {
            return false
        }
        // Buffers the tap handed over before this Margin must not count toward its window.
        drainTapWork()
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

    func captureBufferedPreInterjection(_ request: PostResumeAudioSampleRequest) -> Bool {
        // Called when a Margin finishes and before playback resumes, so the rolling minute ends at the anchor,
        // plus the half second or so the tap decoded ahead of the clock (#1133).
        drainTapWork()
        lock.withLock { heardRecorder?.begin(request) }
        let endMs = request.anchorMediaTimeMs - 5_000
        let startMs = endMs - request.targetDurationMs
        guard startMs >= 0 else { return false }
        // The stored duration is the signature's, which is the length of the audio the buffers really hold. A
        // window with a hole inside it (a tap buffer that never arrived, #1872) passes a check on the first and
        // last media times while holding less audio, and its signature would splice across the hole. So the
        // buffers must run unbroken through the window and hold the target's worth of audio themselves.
        guard let chunks = bufferedChunks(startMs: startMs, endMs: endMs),
              let first = chunks.first, let last = chunks.last,
              last.endMediaTimeMs - first.startMediaTimeMs >= request.targetDurationMs - 250,
              Self.audioDurationMs(of: chunks) >= request.targetDurationMs - 250 else {
            return false
        }
        completionQueue.async { [resultHandler] in
            do {
                let signature = try Self.signature(from: chunks.map(\.buffer))
                resultHandler(.captured(CapturedPostResumePodcastEvidence(
                    request: request,
                    signatureData: signature.dataRepresentation,
                    durationMs: max(1, Int((signature.duration * 1_000).rounded())),
                    anchorOffsetMs: request.anchorMediaTimeMs - first.startMediaTimeMs,
                    windowRole: .preInterjection
                )))
            } catch {
                resultHandler(.failed(request: request, reason: "buffered_pre_interjection_signature_failed:\(error.localizedDescription)"))
            }
        }
        return true
    }

    func noteSeek(at date: Date = Date()) {
        drainTapWork()
        applySeek(at: date)
    }

    /// Forgets everything before a discontinuity: a seek, or buffers the tap had to drop.
    private func applySeek(at date: Date) {
        let heard = lock.withLock { heardRecorder?.noteSeek() ?? [] }
        deliver(heard)
        lock.withLock {
            sparseSchedule.noteSeek(at: date)
            pendingStablePostSeekStartMs = nil
            ring.removeAll(keepingCapacity: true)
            for accumulator in accumulators.values {
                accumulator.restart()
            }
        }
    }

    func prepare(processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
        lock.withLock {
            format = AVAudioFormat(streamDescription: processingFormat)
            tapLock.withLock { tapFormat = format }
            if continuousCollection, let format, heardRecorder == nil,
               format.commonFormat == .pcmFormatFloat32 {
                heardDownsampleFactor = HeardAudioDownsampler.factor(for: format.sampleRate)
                heardRecorder = HeardAudioWindowRecorder(sampleRate: format.sampleRate / Double(heardDownsampleFactor))
            }
        }
    }

    func unprepare() {
        tapLock.withLock { tapFormat = nil }
        lock.withLock {
            format = nil
        }
    }

    /// Runs on the audio thread. It copies the decoded buffer and hands it to the worker; nothing else.
    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: CMItemCount,
        timeRange: CMTimeRange,
        endOfStream: Bool = false
    ) {
        guard frameCount > 0 else { return }
        let frames = Int(frameCount)
        let decodedEndMs = Self.decodedEndMs(timeRange: timeRange)
        let decodedAtMs = DecodedAudioClockGuard.uptimeMs()
        let admitted = tapLock.withLock { () -> Admission? in
            if let decodedEndMs {
                latestDecoded = DecodedAudioClockGuard.DecodedSample(endMediaTimeMs: decodedEndMs, uptimeMs: decodedAtMs)
            }
            guard let tapFormat else { return nil }
            if Double(pendingFrames + frames) > tapFormat.sampleRate * Self.maxPendingSeconds {
                droppedWhilePending = true
                return nil
            }
            pendingFrames += frames
            let gap = droppedWhilePending
            droppedWhilePending = false
            return Admission(format: tapFormat, gapBefore: gap)
        }
        guard let admitted else {
            // No format, or the worker is too far behind to take more. Without a format the windows can't be
            // fed at all, so they fail; behind, the dropped buffer is a gap the worker restarts them after.
            if tapLock.withLock({ tapFormat == nil }) {
                workQueue.async { [self] in failEverythingAsInvalidBuffer() }
            }
            return
        }
        guard let wrapper = AVAudioPCMBuffer(
                pcmFormat: admitted.format,
                bufferListNoCopy: bufferList,
                deallocator: nil
              ) else {
            tapLock.withLock { pendingFrames -= frames }
            workQueue.async { [self] in failEverythingAsInvalidBuffer() }
            return
        }
        wrapper.frameLength = AVAudioFrameCount(frameCount)
        guard let copy = Self.copy(wrapper) else {
            tapLock.withLock {
                pendingFrames -= frames
                droppedWhilePending = true
            }
            return
        }
        let work = TapWork(
            buffer: copy,
            mediaTimeMs: Self.mediaTimeMs(timeRange.start),
            endOfStream: endOfStream,
            gapBefore: admitted.gapBefore
        )
        workQueue.async { [self] in
            processOnWorker(work)
            tapLock.withLock { pendingFrames -= frames }
        }
    }

    private func failEverythingAsInvalidBuffer() {
        let failed = lock.withLock { () -> [Accumulator] in
            let values = Array(accumulators.values)
            accumulators.removeAll()
            return values
        }
        for accumulator in failed {
            report(.failed(request: accumulator.request, reason: "decoded_playback_buffer_invalid"))
        }
        if !failed.isEmpty, !continuousCollection { becameIdle() }
    }

    /// Runs on the worker queue: the ring, the heard-audio recorder and the signature appends for one buffer.
    private func processOnWorker(_ work: TapWork) {
        if work.gapBefore { applySeek(at: Date()) }
        let buffer = work.buffer
        let format = buffer.format
        let frameCount = CMItemCount(buffer.frameLength)
        let mediaTimeMs = work.mediaTimeMs
        let endOfStream = work.endOfStream
        var completed: [Accumulator] = []
        var failed: [(Accumulator, String)] = []
        var heardFinished: [HeardAudioWindow] = []
        let becameEmpty = lock.withLock { () -> Bool in
            if continuousCollection, let mediaTimeMs {
                let durationMs = Int((Double(frameCount) / format.sampleRate * 1_000).rounded())
                // Playback moved back without a noted seek (a Margin's rejoin step-back, #776): drop the first
                // copy of the audio that is about to replay, cutting a buffer the rewind lands inside, so
                // evidence windows never hold it twice.
                if let last = ring.last, mediaTimeMs + Self.rewindToleranceMs < last.endMediaTimeMs {
                    ring = ring.compactMap { Self.trimmed($0, before: mediaTimeMs) }
                }
                // The worker owns this copy and nothing writes to it again, so the ring can keep it as it is.
                ring.append(RingChunk(
                    buffer: buffer,
                    startMediaTimeMs: mediaTimeMs,
                    endMediaTimeMs: mediaTimeMs + max(1, durationMs)
                ))
                let oldestAllowed = mediaTimeMs + max(1, durationMs) - 20_000
                ring.removeAll { $0.endMediaTimeMs < oldestAllowed }
            }
            if let mediaTimeMs, heardRecorder != nil, let channelData = buffer.floatChannelData {
                let stride = buffer.stride
                let channels = stride > 1
                    ? [UnsafePointer(channelData[0])]
                    : (0..<Int(format.channelCount)).map { UnsafePointer(channelData[$0]) }
                let mono = HeardAudioDownsampler.mono(
                    channels: channels, interleavedStride: stride,
                    frameCount: Int(frameCount), factor: heardDownsampleFactor
                )
                heardFinished = heardRecorder?.append(samples: mono, startMediaTimeMs: mediaTimeMs) ?? []
            }
            for (id, accumulator) in accumulators {
                // Playback moved back without a noted seek (a later Margin's rejoin step-back, #776): appending
                // the replayed audio would splice it into this signature under its old start time, so the
                // window starts again from the rewound audio.
                if let mediaTimeMs {
                    if let previousEnd = accumulator.lastBufferEndMs,
                       mediaTimeMs + Self.rewindToleranceMs < previousEnd {
                        accumulator.restart()
                    }
                    accumulator.lastBufferEndMs = mediaTimeMs
                        + Int((Double(frameCount) / format.sampleRate * 1_000).rounded())
                }
                do {
                    let delayFrames = Int64(
                        (Double(accumulator.request.captureDelayMs) * format.sampleRate / 1_000).rounded(.up)
                    )
                    if accumulator.skippedFrames < delayFrames {
                        accumulator.skippedFrames += Int64(frameCount)
                        continue
                    }
                    if accumulator.firstMediaTimeMs == nil {
                        accumulator.firstMediaTimeMs = mediaTimeMs
                    }
                    try appendToSignature(accumulator.generator, buffer)
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

        deliver(heardFinished)
        for accumulator in completed {
            finish(accumulator)
        }
        for (accumulator, reason) in failed {
            report(.failed(request: accumulator.request, reason: reason))
        }
        if becameEmpty {
            if !continuousCollection { becameIdle() }
        }
        scheduleSparseLandmarkIfReady(now: Date())
    }

    func cancelAll(reason: String) {
        drainTapWork()
        let cancelled = lock.withLock { () -> [Accumulator] in
            let values = Array(accumulators.values)
            accumulators.removeAll()
            return values
        }
        for accumulator in cancelled {
            resultHandler(.failed(request: accumulator.request, reason: reason))
        }
        deliver(lock.withLock { heardRecorder?.finishAll(reason: "stopped") ?? [] })
        lock.withLock {
            ring.removeAll()
            generatingLandmarkKeys.removeAll()
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
                anchorOffsetMs: accumulator.request.anchorMediaTimeMs - firstMediaTimeMs,
                windowRole: .postResume
            )))
        }
    }

    private func bufferedChunks(startMs: Int, endMs: Int) -> [RingChunk]? {
        lock.withLock { bufferedChunksWithoutLock(startMs: startMs, endMs: endMs) }
    }

    private func scheduleSparseLandmarkIfReady(now: Date) {
        guard continuousCollection, let itemId else { return }
        let candidate: (key: String, gridIndex: Int?, trigger: EpisodeFingerprintTrigger, epoch: Int, chunks: [RingChunk])? = lock.withLock {
            guard sparseSchedule.isSeekStable(at: now), let current = ring.last?.endMediaTimeMs else { return nil }
            if let grid = sparseSchedule.dueGridIndex(at: current - SparseFingerprintSchedule.targetDurationMs) {
                let start = SparseFingerprintSchedule.initialMediaTimeMs
                    + grid * SparseFingerprintSchedule.periodicIntervalMs
                let end = start + SparseFingerprintSchedule.targetDurationMs
                let key = "grid-\(grid)"
                guard !generatingLandmarkKeys.contains(key),
                      let chunks = bufferedChunksWithoutLock(startMs: start, endMs: end) else { return nil }
                generatingLandmarkKeys.insert(key)
                sparseSchedule.markCaptured(gridIndex: grid)
                return (key, grid, grid == 0 ? .initialPlayback : .periodicPlayback, sparseSchedule.continuityEpoch, chunks)
            }
            if sparseSchedule.continuityEpoch > stablePostSeekServedEpoch {
                if pendingStablePostSeekStartMs == nil { pendingStablePostSeekStartMs = ring.first?.startMediaTimeMs }
                if let start = pendingStablePostSeekStartMs,
                   current - start >= SparseFingerprintSchedule.targetDurationMs {
                    let key = "seek-\(sparseSchedule.continuityEpoch)"
                    guard !generatingLandmarkKeys.contains(key),
                          let chunks = bufferedChunksWithoutLock(
                            startMs: start,
                            endMs: start + SparseFingerprintSchedule.targetDurationMs
                          ) else { return nil }
                    generatingLandmarkKeys.insert(key)
                    pendingStablePostSeekStartMs = nil
                    stablePostSeekServedEpoch = sparseSchedule.continuityEpoch
                    return (key, nil, .stablePostSeek, sparseSchedule.continuityEpoch, chunks)
                }
            }
            return nil
        }
        guard let candidate, let first = candidate.chunks.first, let last = candidate.chunks.last else { return }
        completionQueue.async { [weak self, resultHandler] in
            defer { _ = self?.lock.withLock { self?.generatingLandmarkKeys.remove(candidate.key) } }
            do {
                let signature = try Self.signature(from: candidate.chunks.map(\.buffer))
                resultHandler(.landmark(CapturedEpisodeFingerprintLandmark(
                    itemId: itemId,
                    sourceMediaStartMs: first.startMediaTimeMs,
                    sourceMediaEndMs: last.endMediaTimeMs,
                    anchorMediaTimeMs: first.startMediaTimeMs,
                    continuityEpoch: candidate.epoch,
                    gridIndex: candidate.gridIndex,
                    trigger: candidate.trigger,
                    signatureData: signature.dataRepresentation,
                    durationMs: max(1, Int((signature.duration * 1_000).rounded()))
                )))
            } catch {
                // Sparse landmarks are opportunistic. Per-Margin evidence has
                // its own explicit failure result and must not be conflated.
            }
        }
    }

    /// The ring's buffers across `startMs`..`endMs`, or nil when it doesn't cover the window or has a hole in it.
    /// Buffers the tap dropped leave no trace in the ring except the missing time, so a hole is any buffer that
    /// starts later than the one before it ended.
    private func bufferedChunksWithoutLock(startMs: Int, endMs: Int) -> [RingChunk]? {
        let selected = ring.filter { $0.endMediaTimeMs > startMs && $0.startMediaTimeMs < endMs }
        guard let first = selected.first, let last = selected.last,
              first.startMediaTimeMs <= startMs + 250,
              last.endMediaTimeMs >= endMs - 250,
              Self.isContiguous(selected) else { return nil }
        return selected
    }

    static func isContiguous(_ chunks: [RingChunk]) -> Bool {
        zip(chunks, chunks.dropFirst()).allSatisfy { previous, next in
            next.startMediaTimeMs - previous.endMediaTimeMs <= contiguityToleranceMs
        }
    }

    /// The length of the audio the buffers hold, which is what a signature made from them lasts.
    static func audioDurationMs(of chunks: [RingChunk]) -> Int {
        let seconds = chunks.reduce(0.0) { total, chunk in
            total + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
        }
        return Int((seconds * 1_000).rounded())
    }

    private static func signature(from buffers: [AVAudioPCMBuffer]) throws -> SHSignature {
        let generator = SHSignatureGenerator()
        for buffer in buffers { try generator.append(buffer, at: nil) }
        let signature = generator.signature()
        guard !signature.dataRepresentation.isEmpty else {
            throw PodcastAnchorEvidenceError.signatureGenerationFailed
        }
        return signature
    }

    /// The part of `chunk` before `rewindMs`, or nil when none of it is. A cut buffer is a new, shorter copy:
    /// signature work off the lock may still be reading the original.
    private static func trimmed(_ chunk: RingChunk, before rewindMs: Int) -> RingChunk? {
        guard chunk.startMediaTimeMs < rewindMs else { return nil }
        guard chunk.endMediaTimeMs > rewindMs else { return chunk }
        let keptFrames = AVAudioFrameCount(
            (Double(rewindMs - chunk.startMediaTimeMs) * chunk.buffer.format.sampleRate / 1_000).rounded()
        )
        guard keptFrames > 0, let kept = copy(chunk.buffer, frameLimit: keptFrames) else { return nil }
        return RingChunk(buffer: kept, startMediaTimeMs: chunk.startMediaTimeMs, endMediaTimeMs: rewindMs)
    }

    private static func copy(_ source: AVAudioPCMBuffer, frameLimit: AVAudioFrameCount? = nil) -> AVAudioPCMBuffer? {
        let frames = min(source.frameLength, frameLimit ?? source.frameLength)
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: frames
        ) else { return nil }
        destination.frameLength = frames
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { return nil }
            let count = min(Int(sourceBuffers[index].mDataByteSize), Int(destinationBuffers[index].mDataByteSize))
            memcpy(destinationData, sourceData, count)
            destinationBuffers[index].mDataByteSize = UInt32(count)
        }
        return destination
    }

    private static func decodedEndMs(timeRange: CMTimeRange) -> Int? {
        guard timeRange.start.isValid, timeRange.start.isNumeric else { return nil }
        if timeRange.duration.isValid, timeRange.duration.isNumeric {
            return mediaTimeMs(CMTimeRangeGetEnd(timeRange))
        }
        return mediaTimeMs(timeRange.start)
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
