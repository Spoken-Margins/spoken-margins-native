import AVFoundation
import SessionKitAudio

/// Keep platform permission handling outside the shared iOS/watchOS helper.
@MainActor
final class DesktopAudio {
    let playback = SystemSpeechPlaybackClient(voiceIdentifier: nil)
    let recorder: SystemRecordingClient
    let transcriber: SystemSpeechTranscriptionClient
    private(set) var targetID: String?

    init(directory: URL) {
        recorder = SystemRecordingClient(baseDirectory: directory)
        transcriber = SystemSpeechTranscriptionClient(baseDirectory: directory)
    }

    func prepare(_ text: String) throws {
        try playback.stop()
        targetID = try playback.prepareSpeechText(text)
    }

    func play(from offset: Int, rate: Double) throws {
        guard let targetID else { return }
        try playback.setPlaybackRate(rate)
        try playback.play(targetId: targetID, from: offset)
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
