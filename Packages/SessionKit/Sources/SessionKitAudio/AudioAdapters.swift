import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

public final class SystemSpeechPlaybackClient: AudioPlaybackClient {
    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif
    private var preparedSpeechText = ""

    public init() {}

    public func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        preparedSpeechText = normalized
        return normalized
    }

    public func play(targetId: String) throws {
        #if canImport(AVFoundation)
        guard !preparedSpeechText.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.continueSpeaking()
            return
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: preparedSpeechText)
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
        #endif
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        synthesizer.pauseSpeaking(at: .word)
        #endif
    }
}

public final class SystemRecordingClient: RecordingClient {
    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    #endif
    private let fileManager: FileManager
    private let baseDirectory: URL?

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public static func requestRecordPermission() async -> Bool {
        #if canImport(AVFoundation)
        #if os(iOS) || os(watchOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    public func beginRecording() throws {
        #if canImport(AVFoundation)
        #if os(iOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            throw SessionKitError.persistenceFailed("recording_permission_denied")
        case .undetermined:
            throw SessionKitError.persistenceFailed("recording_permission_required")
        @unknown default:
            throw SessionKitError.persistenceFailed("recording_permission_unknown")
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
        #endif
        let directory = try recordingsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw SessionKitError.persistenceFailed("recording_failed")
        }
        self.recorder = recorder
        self.currentURL = url
        #else
        throw SessionKitError.persistenceFailed("recording_unavailable")
        #endif
    }

    public func finishRecording(audioRef: String?) throws -> String {
        #if canImport(AVFoundation)
        guard let recorder, let currentURL else {
            if let audioRef { return audioRef }
            throw SessionKitError.invalidCommandForState("finishRecording")
        }
        recorder.stop()
        self.recorder = nil
        self.currentURL = nil
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return relativeRecordingPath(for: currentURL)
        #else
        return audioRef ?? "interjections/system-recording.m4a"
        #endif
    }

    public func cancelRecording() throws {
        #if canImport(AVFoundation)
        let url = currentURL
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        currentURL = nil
        if let url {
            try? fileManager.removeItem(at: url)
        }
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }

    private func recordingsDirectory() throws -> URL {
        if let baseDirectory {
            return baseDirectory.appending(path: "interjections", directoryHint: .isDirectory)
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(path: "SpokenMargins/interjections", directoryHint: .isDirectory)
    }

    private func relativeRecordingPath(for url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "SpokenMargins/") {
            return String(path[range.lowerBound...])
        }
        return path
    }
}
