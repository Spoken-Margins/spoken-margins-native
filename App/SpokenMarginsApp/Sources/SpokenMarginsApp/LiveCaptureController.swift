import AVFoundation
import Foundation
import SessionKit

/// Drives the Live capture screen (#2481): writes the session config the broadcast extension reads, polls the
/// extension's status file, keeps the Margins added during the capture, and hands the finished capture to the
/// model to import. The audio itself is written by the extension; this never touches it until Finish.
@MainActor
final class LiveCaptureController: ObservableObject {
    @Published private(set) var sessionId: String
    @Published private(set) var status: LiveCaptureStatus?
    @Published private(set) var margins: [LiveCaptureMargin] = []
    @Published private(set) var now = Date()
    @Published private(set) var isFinishing = false
    @Published var errorMessage: String?

    let container: URL?
    private var pollTask: Task<Void, Never>?

    init() {
        container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LiveCaptureFiles.appGroupIdentifier)
        sessionId = "live-\(UUID().uuidString.lowercased())"
    }

    /// Picks the session: an earlier capture that has audio and was never imported is reopened, so closing the
    /// screen never loses a capture; otherwise a new one starts. Writes the config before any broadcast starts.
    func prepare(transcribe: Bool) {
        guard let container else {
            errorMessage = "The shared App Group folder is unavailable, so the capture extension can't write audio."
            return
        }
        if let previous = LiveCaptureFiles.read(LiveCaptureSessionConfig.self, from: LiveCaptureFiles.configURL(in: container)),
           let previousStatus = LiveCaptureFiles.read(LiveCaptureStatus.self, from: LiveCaptureFiles.statusURL(id: previous.sessionId, in: container)),
           previousStatus.samplesWritten > 0 {
            sessionId = previous.sessionId
            margins = LiveCaptureFiles.read([LiveCaptureMargin].self, from: LiveCaptureFiles.marginsURL(id: previous.sessionId, in: container)) ?? []
        }
        let config = LiveCaptureSessionConfig(sessionId: sessionId, createdAt: Date(), transcribe: transcribe)
        do {
            try LiveCaptureFiles.write(config, to: LiveCaptureFiles.configURL(in: container))
        } catch {
            errorMessage = "Couldn't prepare the capture: \(error.localizedDescription)"
        }
        startPolling()
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() {
        now = Date()
        guard let container else { return }
        status = LiveCaptureFiles.read(LiveCaptureStatus.self, from: LiveCaptureFiles.statusURL(id: sessionId, in: container))
    }

    var isRunning: Bool { status?.state == .running }

    /// Audio arrived in the last two seconds.
    var isReceivingAudio: Bool {
        guard isRunning, let last = status?.lastBufferAt else { return false }
        return now.timeIntervalSince(last) < 2
    }

    var elapsedMs: Int {
        guard let first = status?.firstBufferAt else { return 0 }
        if isRunning { return LiveCaptureMargin.offsetMs(now: now, firstBufferAt: first) }
        return status?.durationMs ?? 0
    }

    var canFinish: Bool {
        guard let status, !isFinishing else { return false }
        return status.state != .running && status.samplesWritten > 0
    }

    func addMargin(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let margin = LiveCaptureMargin(
            id: UUID().uuidString.lowercased(),
            text: trimmed,
            offsetMs: LiveCaptureMargin.offsetMs(now: Date(), firstBufferAt: status?.firstBufferAt),
            createdAt: Date()
        )
        margins.append(margin)
        saveMargins()
    }

    func removeMargin(id: String) {
        margins.removeAll { $0.id == id }
        saveMargins()
    }

    private func saveMargins() {
        guard let container else { return }
        try? LiveCaptureFiles.write(margins, to: LiveCaptureFiles.marginsURL(id: sessionId, in: container))
    }

    /// Imports the capture as a Library item with its Margins. The raw capture files are removed only after the
    /// item is saved, so a failed import leaves them for another try.
    func finish(model: Gate1AppModel, transcribe: Bool) async -> Bool {
        guard let container, canFinish, let status else { return false }
        isFinishing = true
        defer { isFinishing = false }
        do {
            try await model.importLiveCapture(
                pcmURL: LiveCaptureFiles.audioURL(id: sessionId, in: container),
                margins: margins,
                startedAt: status.firstBufferAt ?? status.startedAt,
                transcribe: transcribe
            )
            stopPolling()
            try? FileManager.default.removeItem(at: LiveCaptureFiles.sessionDirectory(id: sessionId, in: container))
            try? FileManager.default.removeItem(at: LiveCaptureFiles.configURL(in: container))
            return true
        } catch {
            errorMessage = "Couldn't save the capture: \(error.localizedDescription)"
            return false
        }
    }

    /// Throws the capture away: its audio, Margins and config.
    func discard() {
        guard let container else { return }
        stopPolling()
        try? FileManager.default.removeItem(at: LiveCaptureFiles.sessionDirectory(id: sessionId, in: container))
        try? FileManager.default.removeItem(at: LiveCaptureFiles.configURL(in: container))
    }
}

/// Converts the extension's 16 kHz mono 16-bit file to AAC in an .m4a, the format the audio importer and the
/// player already handle.
enum LiveCaptureAudioExport {
    enum Failure: Error, LocalizedError {
        case empty
        var errorDescription: String? { "The capture has no audio." }
    }

    nonisolated static func exportM4A(pcmURL: URL, to destination: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LiveCaptureFiles.sampleRate, channels: 1, interleaved: false) else {
            throw Failure.empty
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: LiveCaptureFiles.sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let input = try FileHandle(forReadingFrom: pcmURL)
        defer { try? input.close() }
        var framesWritten = 0
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunkFrames = Int(LiveCaptureFiles.sampleRate) * 5
            while let data = try input.read(upToCount: chunkFrames * LiveCaptureFiles.bytesPerSample), data.count >= 2 {
                let frames = data.count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channel = buffer.floatChannelData?[0] else { throw Failure.empty }
                buffer.frameLength = AVAudioFrameCount(frames)
                data.withUnsafeBytes { raw in
                    for index in 0..<frames {
                        let bits = raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)
                        channel[index] = Float(Int16(bitPattern: UInt16(littleEndian: bits))) / 32_768
                    }
                }
                try output.write(from: buffer)
                framesWritten += frames
            }
            // The file is finished when `output` goes out of scope here.
        }
        guard framesWritten > 0 else { throw Failure.empty }
    }
}
