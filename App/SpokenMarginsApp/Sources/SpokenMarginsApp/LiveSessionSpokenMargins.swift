import Combine
import Foundation
import SessionKit
import SessionKitAudio

#if canImport(CallKit)
import CallKit
#endif

/// Spoken Margins in a live session (#2487). The phone records them with the app's own Margin recorder, the Watch
/// sends them in, and both are transcribed on the device with the app's Margin transcription, so their words feed
/// the transcript line-up's hint matching like a typed Margin.
enum LiveSessionSpokenMargins {
    /// Posted on the main actor after the stored session changed outside `LiveSessionController`
    /// (a Watch Margin arrived, or a transcript finished).
    static let changedOnDisk = Notification.Name("LiveSessionSpokenMargins.changedOnDisk")

    /// Changes the stored session holding `marginId` on the file worker (off the main thread) and, when it changed,
    /// tells the open screen. `body` returns true when it changed something.
    @MainActor
    static func updateStored(
        in files: LiveSessionFileWorker = .shared, marginId: String, _ body: @escaping @Sendable (inout LiveSession) -> Bool
    ) async {
        guard await files.update(marginId: marginId, body) != nil else { return }
        NotificationCenter.default.post(name: changedOnDisk, object: nil)
    }

    /// The on-device transcript of a spoken Margin, or nil when speech recognition isn't allowed or heard nothing.
    static func transcribe(audioPath: String) async -> String? {
        let text = try? await SystemSpeechTranscriptionClient().transcribe(audioPath: audioPath)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Transcribes each spoken Margin in an unsaved session that has no words yet, and files the words in.
    @MainActor
    static func transcribeMissing() async {
        for margin in await LiveSessionFileWorker.shared.spokenWithoutWords() {
            guard let text = await transcribe(audioPath: margin.audioPath) else { continue }
            let id = margin.marginId
            await updateStored(marginId: id) { $0.setTranscript(text, forMarginId: id) }
        }
    }

    /// True while a phone call (Teams, FaceTime, a carrier call) is going on. The call holds the phone's microphone,
    /// even muted, so a phone recording would capture nothing; the Watch's microphone still works.
    @MainActor
    static var isOnACall: Bool {
        #if canImport(CallKit) && os(iOS)
        return callObserver.calls.contains { !$0.hasEnded }
        #else
        return false
        #endif
    }

    #if canImport(CallKit) && os(iOS)
    @MainActor private static let callObserver = CXCallObserver()
    #endif
}

/// Records a spoken Margin on the phone during a live session with the app's Margin recorder (`SystemRecordingClient`),
/// so the file is made and named exactly as an ordinary spoken Margin's. It is an actor: activating and deactivating
/// the audio session and finalizing the file block, so they run off the main thread, one call at a time. The caller
/// checks for a call and the microphone permission (`checkCanRecord`) first, so `start` has no suspension point a
/// `stop` could slip into.
actor LiveSessionPhoneRecorder {
    enum Failure: LocalizedError {
        case onACall
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .onACall: "A call is using the phone's microphone. Speak the Margin on your Apple Watch, or type it."
            case .microphoneDenied: "Spoken Margins can't use the microphone. Turn it on in Settings › Spoken Margins."
            }
        }
    }

    struct Recording: Sendable {
        var audioPath: String
        var startedAt: Date
        var durationMs: Int
    }

    private let recorder = SystemRecordingClient(deactivateSessionOnFinish: true)
    private var startedAt: Date?

    /// Throws when a call holds the microphone or the listener hasn't allowed it.
    @MainActor
    static func checkCanRecord() async throws {
        guard !LiveSessionSpokenMargins.isOnACall else { throw Failure.onACall }
        guard await SystemRecordingClient.requestRecordPermission() else { throw Failure.microphoneDenied }
    }

    func start() throws {
        guard startedAt == nil else { return }
        try recorder.beginRecording()
        startedAt = Date()
    }

    /// Stops and returns the recording's path, when it started, and how long it ran.
    func stop() throws -> Recording? {
        guard let startedAt else { return nil }
        self.startedAt = nil
        let path = try recorder.finishRecording(audioRef: nil)
        return Recording(
            audioPath: path, startedAt: startedAt,
            durationMs: max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
        )
    }

    func cancel() {
        guard startedAt != nil else { return }
        startedAt = nil
        try? recorder.cancelRecording()
    }

    /// False once iOS has stopped the recorder on its own (a call, another app's audio, our own player taking the
    /// audio session). What it took in up to then is still in its file.
    func isCapturing() -> Bool {
        guard startedAt != nil else { return false }
        return recorder.captureReading()?.recorderRunning ?? false
    }
}

/// Owns the phone's spoken Margin while it records, for the life of the app, not of a screen (#3489). The recording
/// used to belong to the live session screen: Close, End, or iOS rebuilding the screen after the phone locked let go
/// of it, and the Margin was never filed. Now every way a recording ends files it into its session in the store, at
/// the moment it was started. Only Discard throws it away.
@MainActor
final class LiveSessionSpokenCapture: ObservableObject {
    static let shared = LiveSessionSpokenCapture()

    /// The session the phone is recording a spoken Margin for, or nil.
    @Published private(set) var sessionId: String?
    /// Something the listener should hear about a recording that no screen was showing when it happened. The open
    /// live session screen shows it once.
    @Published var notice: String?

    private let recorder = LiveSessionPhoneRecorder()
    private let files: LiveSessionFileWorker
    private var starting: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var cardUpdate: Task<Void, Never>?
    private var finishObserver: NSObjectProtocol?

    init(files: LiveSessionFileWorker = .shared) {
        self.files = files
        // Finish on the Lock Screen card matters most when no screen is open, so it is heard here, not by a screen (#3499).
        finishObserver = NotificationCenter.default.addObserver(
            forName: LiveSessionFinishMargin.requested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.stopAndFile() }
        }
    }

    func isRecording(for id: String?) -> Bool { id != nil && sessionId == id }

    /// Starts recording a spoken Margin for `id`. During a call it says to use the Watch instead: the call holds the
    /// phone's microphone, so nothing would be recorded.
    func start(sessionId id: String) {
        guard sessionId == nil else { return }
        sessionId = id
        starting = Task { [weak self, recorder] in
            do {
                try await LiveSessionPhoneRecorder.checkCanRecord()
                try await recorder.start()
                self?.watchRecorder(for: id)
                self?.syncCard(for: id)
            } catch {
                if self?.sessionId == id { self?.sessionId = nil }
                self?.notice = ListenerErrorText.message(for: error)
            }
        }
    }

    /// Stops the recording, whichever session it is for, and files it there. The returned task finishes once the
    /// Margin is in the store, so an End can wait for it. Nil when nothing was recording.
    @discardableResult
    func stopAndFile() -> Task<Void, Never>? {
        guard let id = sessionId else { return nil }
        sessionId = nil
        watcher?.cancel()
        watcher = nil
        let started = starting
        return Task { [weak self, recorder, files] in
            await started?.value // a stop tapped while the start was still opening the microphone waits for it
            self?.syncCard(for: id)
            do {
                guard let recording = try await recorder.stop() else { return }
                await Self.file(recording, into: id, files: files)
            } catch {
                self?.notice = ListenerErrorText.line(prefix: "Couldn't save the spoken Margin:", error: error)
            }
        }
    }

    /// Throws the recording away. Only for a session the listener is discarding.
    func cancel(sessionId id: String) {
        guard sessionId == id else { return }
        sessionId = nil
        watcher?.cancel()
        watcher = nil
        Task { [recorder, starting] in
            await starting?.value
            await recorder.cancel()
        }
    }

    /// The Lock Screen card says a spoken Margin records, with Finish, or goes back to Mark (#3499). One update at a
    /// time, each following the recording as it is when written.
    func syncCard(for id: String) {
        let previous = cardUpdate
        cardUpdate = Task { [weak self] in
            await previous?.value
            await LiveSessionActivities.showRecording(isRecording: { self?.sessionId == id }, sessionId: id)
        }
    }

    /// iOS can stop the recorder without telling this screen (#3489: the Margin recorded while the phone was locked).
    /// When it has, file what it took in at once, so the Margin is there whatever the listener taps next.
    private func watchRecorder(for id: String) {
        watcher?.cancel()
        watcher = Task { [weak self, recorder] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self?.sessionId == id else { return }
                if await recorder.isCapturing() { continue }
                guard let self, sessionId == id else { return }
                stopAndFile()
                notice = "The phone stopped recording your spoken Margin. What you said up to then is saved."
                return
            }
        }
    }

    private static func file(_ recording: LiveSessionPhoneRecorder.Recording, into sessionId: String, files: LiveSessionFileWorker) async {
        let marginId = "phone-\(UUID().uuidString.lowercased())"
        let filed = await files.attachSpokenMargin(
            sessionId: sessionId, marginId: marginId, audioPath: recording.audioPath, markedAt: recording.startedAt,
            durationMs: recording.durationMs, spokenOn: "phone"
        )
        guard filed != nil else { return }
        NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
        guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: recording.audioPath) else { return }
        await LiveSessionSpokenMargins.updateStored(in: files, marginId: marginId) { $0.setTranscript(text, forMarginId: marginId) }
    }
}
