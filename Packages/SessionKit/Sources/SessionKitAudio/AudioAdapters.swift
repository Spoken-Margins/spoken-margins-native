import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Speech)
import Speech
#endif

public final class SystemSpeechPlaybackClient: AudioPlaybackClient {
    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif
    private var preparedSourceText = ""
    private var preparedSpeechText = ""
    private var lastTargetId: String?
    private var lastStartOffset = 0
    private var paused = false

    public init() {}

    public func prepareSpeechText(_ text: String) throws -> String {
        preparedSourceText = text
        let normalized = SpeechTextNormalizer.normalize(text)
        preparedSpeechText = normalized
        return normalized
    }

    public func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        #if canImport(AVFoundation)
        let textToSpeak = speechText(from: charOffset)
        guard !textToSpeak.isEmpty else {
            throw SessionKitError.invalidCommandForState("playback_text_empty")
        }
        if synthesizer.isSpeaking {
            if paused, lastTargetId == targetId, lastStartOffset == charOffset {
                synthesizer.continueSpeaking()
                paused = false
                return
            }
            synthesizer.stopSpeaking(at: .immediate)
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = AVSpeechUtterance(string: textToSpeak)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = preferredVoice()
        lastTargetId = targetId
        lastStartOffset = charOffset
        paused = false
        synthesizer.speak(utterance)
        #else
        if preparedSpeechText.isEmpty {
            throw SessionKitError.invalidCommandForState("playback_text_empty")
        }
        #endif
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        paused = synthesizer.pauseSpeaking(at: .word)
        #endif
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        paused = false
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }

    private func speechText(from charOffset: Int) -> String {
        guard !preparedSourceText.isEmpty else { return preparedSpeechText }
        let clamped = max(0, min(charOffset, preparedSourceText.count))
        let start = preparedSourceText.index(preparedSourceText.startIndex, offsetBy: clamped)
        return SpeechTextNormalizer.normalize(String(preparedSourceText[start...]))
    }

    #if canImport(AVFoundation)
    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let preferredLanguage = Locale.preferredLanguages.first ?? Locale.current.identifier
        let languagePrefix = String(preferredLanguage.prefix(2)).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matching = voices.filter { voice in
            voice.language.lowercased().hasPrefix(languagePrefix)
        }
        let candidates = matching.isEmpty ? voices : matching
        return candidates.first { voice in
            voice.name.localizedCaseInsensitiveContains("Siri") ||
            voice.identifier.localizedCaseInsensitiveContains("siri")
        } ?? candidates.first { voice in
            if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
                return voice.quality == .premium || voice.quality == .enhanced
            }
            return false
        } ?? AVSpeechSynthesisVoice(language: preferredLanguage)
    }
    #endif
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

public final class SystemSpeechTranscriptionClient: @unchecked Sendable {
    private let fileManager: FileManager
    private let baseDirectory: URL?

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func transcribe(audioPath: String) async throws -> String {
        #if canImport(Speech)
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw SessionKitError.persistenceFailed("speech_recognition_not_authorized")
        }
        let url = try audioURL(for: audioPath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionKitError.persistenceFailed("audio_file_missing")
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(iOS 13.0, macOS 10.15, *) {
            request.requiresOnDeviceRecognition = false
        }
        return try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !didFinish {
                    didFinish = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal, !didFinish else { return }
                didFinish = true
                let transcript = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if transcript.isEmpty {
                    continuation.resume(throwing: SessionKitError.persistenceFailed("empty_transcript"))
                } else {
                    continuation.resume(returning: transcript)
                }
            }
        }
        #else
        throw SessionKitError.persistenceFailed("speech_recognition_unavailable")
        #endif
    }

    #if canImport(Speech)
    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    #endif

    private func audioURL(for path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        if url.isFileURL, fileManager.fileExists(atPath: url.path) {
            return url
        }
        let support = try baseDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        if path.hasPrefix("SpokenMargins/") {
            return support.appending(path: path)
        }
        if path.hasPrefix("interjections/") {
            return support.appending(path: "SpokenMargins").appending(path: path)
        }
        return support.appending(path: path)
    }
}
