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

    /// Changes the stored session on the file worker (off the main thread) and, when it changed, tells the open
    /// screen. `body` returns true when it changed something.
    @MainActor
    static func updateStored(_ body: @escaping @Sendable (inout LiveSession) -> Bool) async {
        guard await LiveSessionFileWorker.shared.update(body) != nil else { return }
        NotificationCenter.default.post(name: changedOnDisk, object: nil)
    }

    /// The on-device transcript of a spoken Margin, or nil when speech recognition isn't allowed or heard nothing.
    static func transcribe(audioPath: String) async -> String? {
        let text = try? await SystemSpeechTranscriptionClient().transcribe(audioPath: audioPath)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Transcribes each spoken Margin in the stored session that has no words yet, and files the words in.
    @MainActor
    static func transcribeMissing() async {
        guard let session = await LiveSessionFileWorker.shared.load() else { return }
        for margin in session.margins where margin.isSpoken && margin.spokenTranscript == nil {
            guard let audioPath = margin.audioPath, let text = await transcribe(audioPath: audioPath) else { continue }
            let id = margin.id
            await updateStored { $0.setTranscript(text, forMarginId: id) }
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
}
