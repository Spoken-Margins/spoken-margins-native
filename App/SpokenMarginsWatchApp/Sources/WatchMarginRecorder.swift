import AVFoundation
import CryptoKit
import Foundation

/// Records a spoken Margin on the Watch (#2487). During a phone call the call holds the iPhone's microphone, but the
/// Watch's microphone still records. A finished recording is handed to `WatchLink`, which keeps it until the phone
/// says "filed" (slice 1b, #2531).
@MainActor
final class WatchMarginRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let capture = WatchMarginCapture()
    private let link: WatchLink
    private var currentId: String?
    /// True while a start or stop is still with the capture actor, so a second tap waits its turn.
    private var isSwitching = false

    init(link: WatchLink = .shared) {
        self.link = link
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func toggle() {
        guard !isSwitching else { return }
        isSwitching = true
        Task {
            if isRecording { await stop() } else { await start() }
            isSwitching = false
        }
    }

    func start() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Spoken Margins can't use the microphone. Turn it on in the Watch app on your iPhone.")
            return
        }
        let id = UUID().uuidString.lowercased()
        do {
            try await capture.start(id: id)
            currentId = id
            state = .recording(since: Date())
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stop() async {
        guard case .recording(let since) = state, let id = currentId else { return }
        currentId = nil
        state = .idle
        guard let finished = await capture.stop() else {
            state = .failed("The recording didn't save.")
            return
        }
        link.record(finished, id: id, wallStart: since)
    }
}

/// The Watch's microphone and recording files (#2487). Activating the audio session, starting and stopping the
/// recorder block, so they run on this actor, off the main thread. It also closes the file and computes its checksum,
/// so "Saved on Watch" means the bytes are on disk.
actor WatchMarginCapture {
    struct Finished: Sendable {
        var url: URL
        var duration: TimeInterval
        var sha256: String
    }

    private var recorder: AVAudioRecorder?
    private var url: URL?

    func start(id: String) throws {
        guard recorder == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        guard let directory = WatchLinkFiles.recordingsDirectory() else { throw CaptureError.noFolder }
        let url = directory.appending(path: "\(id).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ])
        guard recorder.record() else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw CaptureError.wouldNotStart
        }
        self.recorder = recorder
        self.url = url
    }

    /// Stops the recorder, releases the microphone and checksums the closed file. Nil when nothing was recording or
    /// the file can't be read.
    func stop() -> Finished? {
        guard let recorder, let url else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.url = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let sha256 = Self.digest(of: url) else { return nil }
        return Finished(url: url, duration: duration, sha256: sha256)
    }

    /// The file's SHA-256, lower-case hex, as the phone's inbox computes it.
    nonisolated static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func duration(of url: URL) -> TimeInterval {
        (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
    }

    private enum CaptureError: LocalizedError {
        case wouldNotStart
        case noFolder
        var errorDescription: String? {
            switch self {
            case .wouldNotStart: "The microphone didn't start."
            case .noFolder: "The Watch has no room for the recording."
            }
        }
    }
}
