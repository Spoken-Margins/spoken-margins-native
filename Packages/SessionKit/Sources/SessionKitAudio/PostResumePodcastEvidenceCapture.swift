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
    case failed(request: PostResumeAudioSampleRequest, windowRole: CapturedPostResumePodcastEvidence.WindowRole, reason: String)
}

/// Owns the short-lived state behind one AVPlayer audio tap. It is armed only
/// after a Margin is recorded and releases each signature generator as soon as
/// its bounded post-resume sample is complete. Multiple closely spaced Margins
/// share this tap and receive the same decoded playback buffers independently.
final class PostResumePodcastEvidenceTapContext: @unchecked Sendable {
    typealias ResultHandler = @Sendable (PostResumePodcastEvidenceCaptureResult) -> Void

    private final class Accumulator: @unchecked Sendable {
        let request: PostResumeAudioSampleRequest
        var generator = SHSignatureGenerator()
        var appendedFrames: Int64 = 0
        var skippedFrames: Int64 = 0
        var firstMediaTimeMs: Int?

        init(request: PostResumeAudioSampleRequest) {
            self.request = request
        }
    }

    private struct RingChunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let startMediaTimeMs: Int
        let endMediaTimeMs: Int
    }

    private struct CallbackChunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let timeRange: CMTimeRange
        let endOfStream: Bool
        let generation: Int
        let continuityGeneration: Int
    }

    private let lock = NSLock()
    private let callbackBufferLock = NSLock()
    private let completionQueue = DispatchQueue(
        label: "com.spokenmargins.podcast-post-resume-evidence",
        qos: .utility
    )
    private let resultHandler: ResultHandler
    private let becameIdle: @Sendable () -> Void
    private let continuousCollection: Bool
    private let itemId: String?
    private var format: AVAudioFormat?
    private var availableCallbackBuffers: [AVAudioPCMBuffer] = []
    private var callbackGeneration = 0
    private var continuityGeneration = 0
    private var lastProcessedEndMediaTimeMs: Int?
    private var accumulators: [String: Accumulator] = [:]
    private var ring: [RingChunk] = []
    private var sparseSchedule = SparseFingerprintSchedule()
    private var pendingStablePostSeekStartMs: Int?
    private var generatingLandmarkKeys: Set<String> = []

    var retainsContinuousCollection: Bool { continuousCollection }

    private static func key(for request: PostResumeAudioSampleRequest) -> String {
        "\(request.sessionId)::\(request.interjectionId)"
    }

    init(
        resultHandler: @escaping ResultHandler,
        becameIdle: @escaping @Sendable () -> Void,
        continuousCollection: Bool = false,
        itemId: String? = nil
    ) {
        self.resultHandler = resultHandler
        self.becameIdle = becameIdle
        self.continuousCollection = continuousCollection
        self.itemId = itemId
    }

    func arm(_ request: PostResumeAudioSampleRequest) -> Bool {
        guard request.targetDurationMs >= PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs else {
            return false
        }
        let armed = lock.withLock {
            let key = Self.key(for: request)
            if let existing = accumulators[key] {
                guard let newer = request.attemptGeneration(for: .postResume),
                      let older = existing.request.attemptGeneration(for: .postResume),
                      newer > older else { return false }
            }
            accumulators[key] = Accumulator(request: request)
            return true
        }
        return armed
    }

    func notePlaybackProgress(mediaTimeMs: Int) {
        let stalled = lock.withLock { () -> [Accumulator] in
            let baseline = lastProcessedEndMediaTimeMs
            let failed = accumulators.filter { _, accumulator in
                mediaTimeMs - max(accumulator.request.anchorMediaTimeMs, baseline ?? accumulator.request.anchorMediaTimeMs) >= 5_000
            }
            for key in failed.keys { accumulators.removeValue(forKey: key) }
            return Array(failed.values)
        }
        for accumulator in stalled {
            resultHandler(.failed(request: accumulator.request, windowRole: .postResume, reason: "decoded_playback_no_buffer_while_advancing"))
        }
    }

    func captureBufferedPreInterjection(_ request: PostResumeAudioSampleRequest) -> Bool {
        let endMs = request.anchorMediaTimeMs
        let startMs = max(0, endMs - request.targetDurationMs)
        guard let selected = bufferedChunks(startMs: startMs, endMs: endMs),
              let chunks = Self.trimmedChunks(selected, startMs: startMs, endMs: endMs),
              let first = chunks.first, let last = chunks.last,
              last.endMediaTimeMs - first.startMediaTimeMs >= PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs else {
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
                resultHandler(.failed(request: request, windowRole: .preInterjection, reason: "buffered_pre_interjection_signature_failed:\(error.localizedDescription)"))
            }
        }
        return true
    }

    func noteSeek(at date: Date = Date()) {
        callbackBufferLock.withLock { continuityGeneration += 1 }
        let invalidated = lock.withLock { () -> [Accumulator] in
            sparseSchedule.noteSeek(at: date)
            pendingStablePostSeekStartMs = nil
            ring.removeAll(keepingCapacity: true)
            lastProcessedEndMediaTimeMs = nil
            let pending = Array(accumulators.values)
            accumulators.removeAll()
            return pending
        }
        for accumulator in invalidated {
            resultHandler(.failed(request: accumulator.request, windowRole: .postResume, reason: "playback_seeked_during_capture"))
        }
    }

    func prepare(maxFrames: CMItemCount = 192_000, processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
        callbackBufferLock.withLock {
            callbackGeneration += 1
            format = AVAudioFormat(streamDescription: processingFormat)
            availableCallbackBuffers = (0..<8).compactMap { _ in
                guard let format else { return nil }
                return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrames))
            }
        }
    }

    func unprepare() {
        callbackBufferLock.withLock {
            callbackGeneration += 1
            format = nil
            availableCallbackBuffers.removeAll()
        }
    }

    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: CMItemCount,
        timeRange: CMTimeRange,
        endOfStream: Bool = false
    ) {
        guard frameCount > 0 else { return }
        let (copied, callbackEpoch, continuityEpoch): (CallbackChunk?, Int, Int) = callbackBufferLock.withLock {
            let callbackEpoch = callbackGeneration
            let continuityEpoch = continuityGeneration
            guard let format,
                  let destination = availableCallbackBuffers.popLast() else { return (nil, callbackEpoch, continuityEpoch) }
            guard frameCount <= destination.frameCapacity,
                  let source = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: bufferList,
                    deallocator: nil
                  ) else {
                availableCallbackBuffers.append(destination)
                return (nil, callbackEpoch, continuityEpoch)
            }
            source.frameLength = AVAudioFrameCount(frameCount)
            guard Self.copy(source, into: destination) else {
                availableCallbackBuffers.append(destination)
                return (nil, callbackEpoch, continuityEpoch)
            }
            return (CallbackChunk(
                buffer: destination,
                timeRange: timeRange,
                endOfStream: endOfStream,
                generation: callbackGeneration,
                continuityGeneration: continuityEpoch
            ), callbackEpoch, continuityEpoch)
        }
        guard let copied else {
            completionQueue.async { [weak self] in
                self?.invalidatePending(
                    reason: "decoded_playback_queue_or_format_gap",
                    callbackGeneration: callbackEpoch,
                    continuityGeneration: continuityEpoch
                )
            }
            return
        }
        completionQueue.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.callbackBufferLock.withLock {
                self.callbackGeneration == copied.generation
                    && self.continuityGeneration == copied.continuityGeneration
            }
            if isCurrent {
                self.processCopied(copied.buffer, timeRange: copied.timeRange, endOfStream: copied.endOfStream)
            }
            self.callbackBufferLock.withLock {
                if self.callbackGeneration == copied.generation {
                    self.availableCallbackBuffers.append(copied.buffer)
                }
            }
        }
    }

    private func processCopied(
        _ buffer: AVAudioPCMBuffer,
        timeRange: CMTimeRange,
        endOfStream: Bool
    ) {
        let frameCount = CMItemCount(buffer.frameLength)
        var completed: [Accumulator] = []
        var failed: [(Accumulator, String)] = []
        var convertedForSignature: AVAudioPCMBuffer?
        let becameEmpty = lock.withLock { () -> Bool in
            let format = buffer.format
            let mediaTimeMs = Self.mediaTimeMs(timeRange.start)
            if let mediaTimeMs, let lastProcessedEndMediaTimeMs,
               abs(mediaTimeMs - lastProcessedEndMediaTimeMs) > 250 {
                ring.removeAll(keepingCapacity: true)
                failed.append(contentsOf: accumulators.values.map { ($0, "decoded_playback_continuity_gap") })
                accumulators.removeAll()
            }
            if let mediaTimeMs {
                lastProcessedEndMediaTimeMs = mediaTimeMs
                    + max(1, Int((Double(frameCount) / format.sampleRate * 1_000).rounded()))
            }
            if continuousCollection,
               let mediaTimeMs,
               let copy = Self.copy(buffer) {
                let durationMs = Int((Double(frameCount) / format.sampleRate * 1_000).rounded())
                ring.append(RingChunk(
                    buffer: copy,
                    startMediaTimeMs: mediaTimeMs,
                    endMediaTimeMs: mediaTimeMs + max(1, durationMs)
                ))
                let oldestAllowed = mediaTimeMs + max(1, durationMs) - 20_000
                ring.removeAll { $0.endMediaTimeMs < oldestAllowed }
            }
            for (id, accumulator) in accumulators {
                do {
                    guard let mediaTimeMs,
                          mediaTimeMs >= accumulator.request.anchorMediaTimeMs - 250,
                          mediaTimeMs <= accumulator.request.anchorMediaTimeMs
                            + accumulator.request.captureDelayMs
                            + accumulator.request.targetDurationMs + 1_000,
                          accumulator.firstMediaTimeMs != nil
                            || mediaTimeMs <= accumulator.request.anchorMediaTimeMs
                                + accumulator.request.captureDelayMs + 2_000 else {
                        failed.append((accumulator, "post_resume_original_interval_unavailable"))
                        accumulators[id] = nil
                        continue
                    }
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
                    if convertedForSignature == nil {
                        convertedForSignature = try Self.signatureBuffer(from: buffer)
                    }
                    try accumulator.generator.append(convertedForSignature!, at: nil)
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
            resultHandler(.failed(request: accumulator.request, windowRole: .postResume, reason: reason))
        }
        if becameEmpty {
            if !continuousCollection { becameIdle() }
        }
        scheduleSparseLandmarkIfReady(now: Date())
    }

    /// Test seam for deterministic synthetic buffers; production capture does
    /// not block the playback thread waiting for worker completion.
    func flushPendingBuffersForTesting() {
        completionQueue.sync {}
    }

    var pendingCaptureCountForTesting: Int { lock.withLock { accumulators.count } }

    private func invalidatePending(reason: String, callbackGeneration: Int, continuityGeneration: Int) {
        let failed = callbackBufferLock.withLock { () -> [Accumulator] in
            guard self.callbackGeneration == callbackGeneration,
                  self.continuityGeneration == continuityGeneration else { return [] }
            return lock.withLock {
                let pending = Array(accumulators.values)
                accumulators.removeAll()
                ring.removeAll(keepingCapacity: true)
                lastProcessedEndMediaTimeMs = nil
                return pending
            }
        }
        for accumulator in failed {
            resultHandler(.failed(request: accumulator.request, windowRole: .postResume, reason: reason))
        }
    }

    /// Reproduces an exhausted callback pool whose queued invalidation drains
    /// only after the caller has changed playback continuity and rearmed.
    func queueGapForTesting(beforeDrain: () -> Void) {
        let gate = DispatchSemaphore(value: 0)
        completionQueue.async { gate.wait() }
        let epochs = callbackBufferLock.withLock { (callbackGeneration, continuityGeneration) }
        completionQueue.async { [weak self] in
            self?.invalidatePending(
                reason: "decoded_playback_queue_or_format_gap",
                callbackGeneration: epochs.0,
                continuityGeneration: epochs.1
            )
        }
        beforeDrain()
        gate.signal()
        flushPendingBuffersForTesting()
    }

    func cancelAll(reason: String) {
        let cancelled = lock.withLock { () -> [Accumulator] in
            let values = Array(accumulators.values)
            accumulators.removeAll()
            return values
        }
        for accumulator in cancelled {
            resultHandler(.failed(request: accumulator.request, windowRole: .postResume, reason: reason))
        }
        lock.withLock {
            ring.removeAll()
            generatingLandmarkKeys.removeAll()
        }
    }

    private func finish(_ accumulator: Accumulator) {
        completionQueue.async { [resultHandler] in
            let signature = accumulator.generator.signature()
            let data = signature.dataRepresentation
            guard !data.isEmpty else {
                resultHandler(.failed(
                    request: accumulator.request,
                    windowRole: .postResume,
                    reason: "signature_generation_failed"
                ))
                return
            }
            guard let firstMediaTimeMs = accumulator.firstMediaTimeMs else {
                resultHandler(.failed(
                    request: accumulator.request,
                    windowRole: .postResume,
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
        lock.withLock {
            let selected = ring.filter { $0.endMediaTimeMs > startMs && $0.startMediaTimeMs < endMs }
            guard let first = selected.first, let last = selected.last,
                  first.startMediaTimeMs <= startMs + 250,
                  last.endMediaTimeMs >= endMs - 250 else { return nil }
            return selected
        }
    }

    private static func trimmedChunks(_ chunks: [RingChunk], startMs: Int, endMs: Int) -> [RingChunk]? {
        var trimmed: [RingChunk] = []
        for chunk in chunks {
            let rate = chunk.buffer.format.sampleRate
            guard rate > 0 else { return nil }
            let frameCount = Int(chunk.buffer.frameLength)
            let firstFrame = min(frameCount, max(0, Int(ceil(Double(startMs - chunk.startMediaTimeMs) * rate / 1_000))))
            let lastFrame = min(frameCount, max(0, Int(floor(Double(endMs - chunk.startMediaTimeMs) * rate / 1_000))))
            guard lastFrame > firstFrame else { continue }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: chunk.buffer.format,
                frameCapacity: AVAudioFrameCount(lastFrame - firstFrame)
            ) else { return nil }
            buffer.frameLength = AVAudioFrameCount(lastFrame - firstFrame)
            let source = UnsafeMutableAudioBufferListPointer(chunk.buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard source.count == destination.count else { return nil }
            let bytesPerFrame = Int(chunk.buffer.format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return nil }
            for index in source.indices {
                let byteOffset = firstFrame * bytesPerFrame
                let byteCount = (lastFrame - firstFrame) * bytesPerFrame
                guard let sourceData = source[index].mData,
                      let destinationData = destination[index].mData,
                      byteOffset + byteCount <= Int(source[index].mDataByteSize),
                      byteCount <= Int(destination[index].mDataByteSize) else { return nil }
                memcpy(destinationData, sourceData.advanced(by: byteOffset), byteCount)
                destination[index].mDataByteSize = UInt32(byteCount)
            }
            let actualStartMs = chunk.startMediaTimeMs + Int((Double(firstFrame) * 1_000 / rate).rounded())
            let actualEndMs = chunk.startMediaTimeMs + Int((Double(lastFrame) * 1_000 / rate).rounded())
            trimmed.append(RingChunk(buffer: buffer, startMediaTimeMs: actualStartMs, endMediaTimeMs: actualEndMs))
        }
        return trimmed.isEmpty ? nil : trimmed
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
            if sparseSchedule.continuityEpoch > 0 {
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

    private func bufferedChunksWithoutLock(startMs: Int, endMs: Int) -> [RingChunk]? {
        let selected = ring.filter { $0.endMediaTimeMs > startMs && $0.startMediaTimeMs < endMs }
        guard let first = selected.first, let last = selected.last,
              first.startMediaTimeMs <= startMs + 250,
              last.endMediaTimeMs >= endMs - 250 else { return nil }
        return selected
    }

    private static func signature(from buffers: [AVAudioPCMBuffer]) throws -> SHSignature {
        let generator = SHSignatureGenerator()
        for buffer in buffers { try generator.append(signatureBuffer(from: buffer), at: nil) }
        let signature = generator.signature()
        guard !signature.dataRepresentation.isEmpty else {
            throw PodcastAnchorEvidenceError.signatureGenerationFailed
        }
        return signature
    }

    /// Converts decoded playback to a supported mono Float32 format on the
    /// worker queue; the audio-tap callback only copies its source buffer.
    private static func signatureBuffer(from source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if source.format.commonFormat == .pcmFormatFloat32,
           !source.format.isInterleaved,
           source.format.channelCount == 1,
           (8_000...48_000).contains(source.format.sampleRate) { return source }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: source.format, to: target),
              let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    max(1, Int(ceil(Double(source.frameLength) * 44_100 / source.format.sampleRate)) + 1_024)
                )
              ) else {
            throw PodcastAnchorEvidenceError.signatureGenerationFailed
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, output.frameLength > 0 else {
            throw error ?? PodcastAnchorEvidenceError.signatureGenerationFailed
        }
        return output
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        guard copy(source, into: destination) else { return nil }
        return destination
    }

    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) -> Bool {
        guard destination.frameCapacity >= source.frameLength else { return false }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { return false }
            let count = min(Int(sourceBuffers[index].mDataByteSize), Int(destinationBuffers[index].mDataByteSize))
            memcpy(destinationData, sourceData, count)
            destinationBuffers[index].mDataByteSize = UInt32(count)
        }
        return true
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
            prepare: { tap, maxFrames, processingFormat in
                PostResumePodcastEvidenceTapFactory.storedContext(for: tap)
                    .prepare(maxFrames: maxFrames, processingFormat: processingFormat)
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
