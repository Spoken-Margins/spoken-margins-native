import CoreMedia
import Foundation
import ReplayKit

/// The live capture broadcast extension (#2481). It keeps only the phone's app audio, converts it to 16 kHz mono
/// 16-bit samples, appends them to the session's file in the App Group, and writes a small status file the app
/// polls. Nothing else happens here: the extension has about 50 MB of memory, so transcription runs in the app
/// after the capture stops. Video and microphone buffers are dropped.
final class LiveCaptureSampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "com.spokenmargins.livecapture.writer")
    private var container: URL?
    private var sessionId = ""
    private var file: FileHandle?
    private var status: LiveCaptureStatus?
    private var resampler = LiveCaptureResampler()
    private var firstPresentationSeconds: Double?
    private var lastStatusWrite = Date.distantPast
    private var levelWindow: [Float] = []

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.sync {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LiveCaptureFiles.appGroupIdentifier) else {
                finishBroadcastWithError(Self.error("The App Group container is unavailable."))
                return
            }
            self.container = container
            let config = LiveCaptureFiles.read(LiveCaptureSessionConfig.self, from: LiveCaptureFiles.configURL(in: container))
            // A broadcast started from Control Center without opening the app first still records; the app
            // finds it by its status file.
            sessionId = config?.sessionId ?? "live-\(UUID().uuidString.lowercased())"
            let audioURL = LiveCaptureFiles.audioURL(id: sessionId, in: container)
            do {
                try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: audioURL.path) {
                    FileManager.default.createFile(atPath: audioURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: audioURL)
                try handle.seekToEnd()
                file = handle
            } catch {
                finishBroadcastWithError(Self.error("Could not open the capture file: \(error.localizedDescription)"))
                return
            }
            let now = Date()
            var started = LiveCaptureStatus(sessionId: sessionId, state: .running, startedAt: now)
            if let previous = LiveCaptureFiles.read(LiveCaptureStatus.self, from: LiveCaptureFiles.statusURL(id: sessionId, in: container)),
               previous.samplesWritten > 0 {
                // A second broadcast into the same session appends; keep its clock.
                started = previous
                started.state = .running
                started.updatedAt = now
            }
            status = started
            writeStatus(force: true)
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        queue.sync { append(sampleBuffer) }
    }

    override func broadcastPaused() {
        queue.sync { writeStatus(force: true) }
    }

    override func broadcastFinished() {
        queue.sync {
            try? file?.synchronize()
            try? file?.close()
            file = nil
            status?.state = .stopped
            writeStatus(force: true)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let file, var status else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        let format = LiveCaptureSourceFormat(
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            formatFlags: asbd.mFormatFlags
        )
        guard let buffers = Self.audioBuffers(sampleBuffer) else { return }
        let mono = LiveCapturePCM.monoSamples(buffers: buffers, format: format)
        guard !mono.isEmpty else {
            status.sourceFormat = format
            status.failure = "Unsupported audio format: \(format.summary)"
            self.status = status
            writeStatus(force: false)
            return
        }
        let resampled = resampler.process(mono, sourceRate: format.sampleRate)
        let now = Date()
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if firstPresentationSeconds == nil {
            firstPresentationSeconds = presentation.isFinite ? presentation : nil
            if status.firstBufferAt == nil { status.firstBufferAt = now }
        }
        var output = Data()
        if let first = firstPresentationSeconds, presentation.isFinite {
            let padding = LiveCapturePCM.silencePaddingSamples(writtenSamples: status.samplesWritten, elapsedSeconds: presentation - first)
            if padding > 0 {
                // Cap a single gap at ten minutes, so a bad timestamp can't fill the disk.
                let capped = min(padding, Int64(LiveCaptureFiles.sampleRate * 600))
                output.append(Data(count: Int(capped) * LiveCaptureFiles.bytesPerSample))
                status.paddedSamples += capped
                status.samplesWritten += capped
            }
        }
        output.append(LiveCapturePCM.int16LittleEndian(resampled))
        do {
            try file.write(contentsOf: output)
        } catch {
            status.failure = "Write failed: \(error.localizedDescription)"
        }
        status.samplesWritten += Int64(resampled.count)
        status.buffersReceived += 1
        if mono.allSatisfy({ $0 == 0 }) { status.zeroBuffers += 1 }
        status.lastBufferAt = now
        status.sourceFormat = format
        levelWindow.append(contentsOf: resampled)
        if levelWindow.count > Int(LiveCaptureFiles.sampleRate) {
            levelWindow.removeFirst(levelWindow.count - Int(LiveCaptureFiles.sampleRate))
        }
        let level = LiveCapturePCM.peakAndRMS(levelWindow)
        status.peak = level.peak
        status.rms = level.rms
        self.status = status
        writeStatus(force: false)
    }

    private func writeStatus(force: Bool) {
        guard let container, var status else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusWrite) >= 0.25 else { return }
        lastStatusWrite = now
        status.updatedAt = now
        self.status = status
        try? LiveCaptureFiles.write(status, to: LiveCaptureFiles.statusURL(id: status.sessionId, in: container))
    }

    /// Copies each AudioBuffer out of the sample buffer.
    private static func audioBuffers(_ sampleBuffer: CMSampleBuffer) -> [Data]? {
        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr, sizeNeeded > 0 else { return nil }
        let listPointer = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        let list = listPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(list).compactMap { buffer in
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return nil }
            return Data(bytes: data, count: Int(buffer.mDataByteSize))
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.spokenmargins.livecapture", code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: message])
    }
}
