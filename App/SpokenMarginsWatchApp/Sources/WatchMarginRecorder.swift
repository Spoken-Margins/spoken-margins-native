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
    /// What this recording was aimed at and whether the Watch paused the phone's item (#3494). Nil while idle.
    @Published private(set) var plan: WatchRecordingPlan?
    /// An item was loaded when this recording began, so the listener chose a target and the screen names it.
    @Published private(set) var choiceWasShown = false

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

    /// Starts, or stops if already recording. `target` is where a new recording is aimed.
    func toggle(target: WatchRecordingTarget) {
        guard !isSwitching else { return }
        isSwitching = true
        Task {
            if isRecording { await stop() } else { await start(target: target) }
            isSwitching = false
        }
    }

    /// Throws the recording away and returns to the first screen, ready to try again (#3494).
    func discardRecording() {
        guard !isSwitching, isRecording else { return }
        isSwitching = true
        Task {
            await discard()
            isSwitching = false
        }
    }

    func start(target: WatchRecordingTarget = .session) async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Spoken Margins can't use the microphone. Turn it on in the Watch app on your iPhone.")
            return
        }
        let id = UUID().uuidString.lowercased()
        do {
            try await capture.start(id: id)
            currentId = id
            let now = Date()
            // Record pauses the phone's item, as a Margin on the phone does (#3494).
            var plan = WatchRecordingPlan.begin(target: target, nowPlaying: link.nowPlaying(now: now), phoneNow: link.phoneTime(of: now))
            // A pause that never left the Watch (the phone out of reach) is not ours to undo later with a Play.
            if let pause = plan.pauseOnStart, !link.sendTransport(pause) { plan.pausedPhone = false }
            self.plan = plan
            choiceWasShown = link.nowPlaying(now: now) != nil
            state = .recording(since: now)
        } catch {
            WatchDiagnostics.failed("recordingStartFailed", error: error)
            state = .failed(ListenerErrorText.line(prefix: "Couldn't start recording:", error: error))
        }
    }

    func stop() async {
        guard case .recording(let since) = state, let id = currentId else { return }
        let plan = self.plan
        currentId = nil
        state = .idle
        self.plan = nil
        let finished = await capture.stop()
        resumePhone(after: plan)
        guard let finished else {
            WatchDiagnostics.failed("recordingNotSaved")
            state = .failed("The recording didn't save.")
            return
        }
        link.record(finished, id: id, wallStart: since, itemTarget: plan?.itemTarget)
    }

    func discard() async {
        guard case .recording = state else { return }
        let plan = self.plan
        currentId = nil
        state = .idle
        self.plan = nil
        await capture.discard()
        resumePhone(after: plan)
    }

    /// Plays the phone's item again, but only if this recording paused it (#3494).
    private func resumePhone(after plan: WatchRecordingPlan?) {
        guard let plan, let play = plan.resumeOnEnd(nowPlaying: link.nowPlaying(now: Date())) else { return }
        link.sendTransport(play)
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

    /// Stops the recorder and deletes what it wrote: a recording the listener threw away is never kept or sent.
    func discard() {
        guard let recorder, let url else { return }
        recorder.stop()
        self.recorder = nil
        self.url = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? FileManager.default.removeItem(at: url)
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
