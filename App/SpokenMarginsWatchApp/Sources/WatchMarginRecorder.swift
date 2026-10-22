import AVFoundation
import Foundation
import WatchConnectivity

/// The WatchConnectivity metadata keys for a spoken Margin. They must match `WatchMarginTransfer.Key` in SessionKit,
/// which the phone reads (the Watch app doesn't link SessionKit).
enum WatchMarginTransferKeys {
    static let kind = "kind"
    static let kindValue = "watchMargin"
    static let id = "id"
    static let wallStart = "wallStart"
    static let duration = "duration"
}

/// The application-context keys the phone sends. They must match `WatchLiveSessionContext` in the iOS app.
enum WatchLiveSessionContextKeys {
    static let startedAt = "liveSessionStartedAt"
    static let startPositionMs = "liveSessionStartPositionMs"
    static let title = "liveSessionTitle"
}

/// Records a spoken Margin on the Watch (#2487) and sends it to the phone. During a phone call the call holds the
/// iPhone's microphone, but the Watch's microphone still records. Each recording is AAC, stamped with the
/// wall-clock moment it started and its length, and goes to the phone with `transferFile`, which keeps trying in
/// the background until the phone has it.
@MainActor
final class WatchMarginRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSent: String?
    @Published private(set) var pendingTransfers = 0
    /// The phone's running live session: its start and the source position at that start.
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var sessionStartPositionMs: Int?
    @Published private(set) var sessionTitle: String?

    private var recorder: AVAudioRecorder?
    private var currentId: String?
    private var currentURL: URL?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        apply(context: WCSession.default.receivedApplicationContext)
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// "about 12:40": the phone session's start position plus the time since it started, when it gave one.
    func aboutPosition(at now: Date) -> String? {
        guard let startedAt = sessionStartedAt, let startMs = sessionStartPositionMs else { return nil }
        let ms = max(0, startMs + Int(now.timeIntervalSince(startedAt) * 1_000))
        let seconds = ms / 1_000
        let clock = seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "about \(clock)"
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Spoken Margins can't use the microphone. Turn it on in the Watch app on your iPhone.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let id = UUID().uuidString.lowercased()
            let url = try Self.recordingsDirectory().appending(path: "\(id).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22_050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            guard recorder.record() else { throw RecorderError.wouldNotStart }
            self.recorder = recorder
            currentId = id
            currentURL = url
            state = .recording(since: Date())
        } catch {
            state = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard case .recording(let since) = state, let recorder, let id = currentId, let url = currentURL else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        currentId = nil
        currentURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        send(url: url, id: id, wallStart: since, duration: duration)
    }

    private func send(url: URL, id: String, wallStart: Date, duration: TimeInterval) {
        guard WCSession.isSupported() else { return }
        let metadata: [String: Any] = [
            WatchMarginTransferKeys.kind: WatchMarginTransferKeys.kindValue,
            WatchMarginTransferKeys.id: id,
            WatchMarginTransferKeys.wallStart: wallStart.timeIntervalSince1970,
            WatchMarginTransferKeys.duration: duration
        ]
        WCSession.default.transferFile(url, metadata: metadata)
        pendingTransfers = WCSession.default.outstandingFileTransfers.count
        lastSent = "Saved. It goes to your iPhone."
    }

    fileprivate func apply(context: [String: Any]) {
        sessionStartedAt = (context[WatchLiveSessionContextKeys.startedAt] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        sessionStartPositionMs = (context[WatchLiveSessionContextKeys.startPositionMs] as? NSNumber)?.intValue
        let title = (context[WatchLiveSessionContextKeys.title] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionTitle = title?.isEmpty == false ? title : nil
    }

    fileprivate func transferFinished(_ url: URL, error: Error?) {
        pendingTransfers = WCSession.default.outstandingFileTransfers.count
        if error == nil {
            try? FileManager.default.removeItem(at: url)
            lastSent = "Sent to your iPhone."
        } else {
            lastSent = "Couldn't send it to your iPhone. It's kept on the Watch."
        }
    }

    private static func recordingsDirectory() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "WatchMargins", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum RecorderError: LocalizedError {
        case wouldNotStart
        var errorDescription: String? { "The microphone didn't start." }
    }
}

extension WatchMarginRecorder: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let sendable = Self.sendableContext(context)
        Task { @MainActor in self.apply(context: sendable.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let sendable = Self.sendableContext(applicationContext)
        Task { @MainActor in self.apply(context: sendable.value) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        let failed = error != nil
        Task { @MainActor in self.transferFinished(url, error: failed ? RecorderError.wouldNotStart : nil) }
    }

    private struct SendableContext: @unchecked Sendable { var value: [String: Any] }

    nonisolated private static func sendableContext(_ context: [String: Any]) -> SendableContext {
        SendableContext(value: context)
    }
}
