import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Speech)
import Speech
#endif

public struct SpeechVoiceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: String

    public init(id: String, name: String, language: String, quality: String) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }
}

public enum SpeechPreviewMode: Sendable {
    case spokenContent
    case appVoice(voiceIdentifier: String?, rate: Float)
    case assistiveTechnology
}

public final class SystemSpeechPlaybackClient: NSObject, AudioPlaybackClient, @unchecked Sendable {
    #if canImport(AVFoundation)
    private var synthesizer = AVSpeechSynthesizer()
    #endif
    private var preparedSourceText = ""
    private var preparedSpeechText = ""
    private var lastTargetId: String?
    private var lastStartOffset = 0
    private var currentOffset: Int?
    private var completedTargetId: String?
    private var playbackComplete = false
    private var paused = false
    private let voiceIdentifier: String?
    private let speechRate: Float
    private let readsSpeechSettingsAtPlayback: Bool

    public override init() {
        self.voiceIdentifier = nil
        self.speechRate = AVSpeechUtteranceDefaultSpeechRate
        self.readsSpeechSettingsAtPlayback = true
        super.init()
        #if canImport(AVFoundation)
        installSynthesizerDelegate()
        #endif
    }

    public init(voiceIdentifier: String? = nil, speechRate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        self.speechRate = speechRate
        self.readsSpeechSettingsAtPlayback = false
        super.init()
        #if canImport(AVFoundation)
        installSynthesizerDelegate()
        #endif
    }

    public static func availableVoiceOptions() -> [SpeechVoiceOption] {
        #if canImport(AVFoundation)
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name < rhs.name
                }
                return lhs.language < rhs.language
            }
            .map { voice in
                SpeechVoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: voiceQualityName(voice)
                )
            }
        #else
        return []
        #endif
    }

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
            replaceSynthesizer()
        } else if paused {
            replaceSynthesizer()
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let utterance = makeUtterance(textToSpeak, mode: playbackSpeechPreviewMode())
        lastTargetId = targetId
        lastStartOffset = charOffset
        currentOffset = charOffset
        completedTargetId = nil
        playbackComplete = false
        paused = false
        synthesizer.speak(utterance)
        #else
        if preparedSpeechText.isEmpty {
            throw SessionKitError.invalidCommandForState("playback_text_empty")
        }
        #endif
    }

    public func preview(_ text: String, mode: SpeechPreviewMode) throws {
        #if canImport(AVFoundation)
        let textToSpeak = SpeechTextNormalizer.normalize(text)
        guard !textToSpeak.isEmpty else {
            throw SessionKitError.invalidCommandForState("preview_text_empty")
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        synthesizer.speak(makeUtterance(textToSpeak, mode: mode))
        #else
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SessionKitError.invalidCommandForState("preview_text_empty")
        }
        #endif
    }

    public func previewSpokenContent(_ text: String) throws {
        try preview(text, mode: .spokenContent)
    }

    public func previewAppVoice(_ text: String, voiceIdentifier: String?, rate: Float) throws {
        try preview(text, mode: .appVoice(voiceIdentifier: voiceIdentifier, rate: rate))
    }

    public func previewAssistiveTechnology(_ text: String) throws {
        try preview(text, mode: .assistiveTechnology)
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking {
            paused = true
            synthesizer.stopSpeaking(at: .immediate)
        }
        #endif
    }

    public func currentCharOffset() -> Int? {
        currentOffset
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        playbackComplete && completedTargetId == targetId
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        paused = false
        playbackComplete = false
        completedTargetId = nil
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

    private func currentSpeechSettings() -> (voiceIdentifier: String?, rate: Float) {
        guard readsSpeechSettingsAtPlayback else {
            return (voiceIdentifier, speechRate)
        }
        let storedVoice = UserDefaults.standard.string(forKey: "speechVoiceIdentifier")
        let storedRate = UserDefaults.standard.double(forKey: "speechRate")
        return (
            storedVoice?.isEmpty == true ? nil : storedVoice,
            storedRate == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(storedRate)
        )
    }

    #if canImport(AVFoundation)
    private func installSynthesizerDelegate() {
        synthesizer.delegate = self
    }

    private func replaceSynthesizer() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer()
        installSynthesizerDelegate()
    }

    private func playbackSpeechPreviewMode() -> SpeechPreviewMode {
        let speechSettings = currentSpeechSettings()
        if readsSpeechSettingsAtPlayback, speechSettings.voiceIdentifier == nil {
            return .spokenContent
        }
        return .appVoice(voiceIdentifier: speechSettings.voiceIdentifier, rate: speechSettings.rate)
    }

    private func makeUtterance(_ text: String, mode: SpeechPreviewMode) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        switch mode {
        case .spokenContent:
            utterance.rate = currentSpeechSettings().rate
        case .appVoice(let voiceIdentifier, let rate):
            utterance.rate = rate
            if let voiceIdentifier,
               let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = configuredVoice
            }
        case .assistiveTechnology:
            utterance.prefersAssistiveTechnologySettings = true
        }
        return utterance
    }
    #endif

}

#if canImport(AVFoundation)
private func voiceQualityName(_ voice: AVSpeechSynthesisVoice) -> String {
    if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
        switch voice.quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }
    return "Default"
}
#endif

#if canImport(AVFoundation)
extension SystemSpeechPlaybackClient: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        currentOffset = lastStartOffset + max(0, characterRange.location)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        currentOffset = preparedSourceText.count
        completedTargetId = lastTargetId
        playbackComplete = true
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        playbackComplete = false
        completedTargetId = nil
    }
}
#endif

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
