import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(MediaPlayer)
import MediaPlayer
#endif

#if canImport(Speech)
import Speech
#endif

#if canImport(UIKit)
import UIKit
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

public final class SystemTextAudioPreparationClient: NSObject, TextAudioPreparationClient, @unchecked Sendable {
    private let outputDirectory: URL?
    private let voiceIdentifier: String?
    private let speechRate: Float
    private let maxSegmentCharacters: Int
    private let allowsSynchronousRendering: Bool
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        outputDirectory: URL? = nil,
        voiceIdentifier: String? = nil,
        speechRate: Float = AVSpeechUtteranceDefaultSpeechRate,
        maxSegmentCharacters: Int = 700,
        allowsSynchronousRendering: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.outputDirectory = outputDirectory
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        self.speechRate = speechRate
        self.maxSegmentCharacters = max(120, maxSegmentCharacters)
        self.allowsSynchronousRendering = allowsSynchronousRendering
        self.fileManager = fileManager
        super.init()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func prepareTextAudio(itemId: String, title: String, text: String) throws -> PreparedTextAudio? {
        try prepareTextAudio(itemId: itemId, title: title, text: text, scope: .complete)
    }

    public func prepareStarterTextAudio(itemId: String, title: String, text: String, targetDurationMs: Int = 30_000) throws -> PreparedTextAudio? {
        try prepareTextAudio(itemId: itemId, title: title, text: text, scope: .starter(targetDurationMs: targetDurationMs))
    }

    private func prepareTextAudio(itemId: String, title: String, text: String, scope: TextAudioRenderScope) throws -> PreparedTextAudio? {
        #if canImport(AVFoundation)
        let normalizedText = SpeechTextNormalizer.normalize(text)
        guard !normalizedText.isEmpty else { return nil }
        let allSegments = Self.textSegments(in: normalizedText, maxSegmentCharacters: maxSegmentCharacters)
        let segments = scope.segments(from: allSegments, speechRate: speechRate)
        guard !segments.isEmpty else { return nil }
        let directory = try resolvedOutputDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let signature = Self.cacheSignature(
            itemId: itemId,
            text: normalizedText,
            voiceIdentifier: voiceIdentifier,
            speechRate: speechRate,
            scope: scope.cacheScope
        )
        let baseName = "\(Self.safePathComponent(itemId))-\(signature)\(scope.fileSuffix)"
        let audioURL = directory.appending(path: "\(baseName).caf")
        let cacheURL = directory.appending(path: "\(baseName).json")
        if let cached = try cachedPreparedAudio(cacheURL: cacheURL, audioURL: audioURL, signature: signature) {
            return cached
        }
        guard allowsSynchronousRendering else {
            return nil
        }
        let rendered = try render(segments: segments, outputURL: audioURL)
        let media = ItemMedia(
            sourceType: .generatedTTSPrerendered,
            url: audioURL.absoluteString,
            durationMs: rendered.timeline.durationMs,
            nativeMediaId: audioURL.absoluteString
        )
        let prepared = PreparedTextAudio(
            normalizedText: normalizedText,
            media: media,
            timeline: rendered.timeline
        )
        try saveCache(prepared, signature: signature, audioURL: audioURL, cacheURL: cacheURL)
        return prepared
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation)
    private func cachedPreparedAudio(cacheURL: URL, audioURL: URL, signature: String) throws -> PreparedTextAudio? {
        guard fileManager.fileExists(atPath: cacheURL.path),
              fileManager.fileExists(atPath: audioURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: cacheURL)
        let cached = try decoder.decode(CachedPreparedTextAudio.self, from: data)
        guard cached.signature == signature else { return nil }
        let media = ItemMedia(
            sourceType: .generatedTTSPrerendered,
            url: audioURL.absoluteString,
            durationMs: cached.timeline.durationMs,
            nativeMediaId: audioURL.absoluteString
        )
        return PreparedTextAudio(
            normalizedText: cached.normalizedText,
            media: media,
            timeline: cached.timeline,
            createdAt: cached.createdAt
        )
    }

    private func saveCache(_ prepared: PreparedTextAudio, signature: String, audioURL: URL, cacheURL: URL) throws {
        let cached = CachedPreparedTextAudio(
            signature: signature,
            normalizedText: prepared.normalizedText,
            audioFileName: audioURL.lastPathComponent,
            timeline: prepared.timeline,
            createdAt: prepared.createdAt
        )
        let data = try encoder.encode(cached)
        try data.write(to: cacheURL, options: [.atomic])
    }

    private func render(segments: [TextAudioSegment], outputURL: URL) throws -> (timeline: TranscriptTimeline, durationMs: Int) {
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let accumulator = AudioFileAccumulator(outputURL: outputURL)
        let synthesizer = AVSpeechSynthesizer()
        var renderedSegments: [MediaTimelineSegment] = []
        var cursorMs = 0
        for (index, segment) in segments.enumerated() {
            let framesBefore = accumulator.totalFrames
            try writeUtterance(segment.text, synthesizer: synthesizer, accumulator: accumulator)
            let frameDelta = max(0, accumulator.totalFrames - framesBefore)
            let segmentDurationMs = accumulator.milliseconds(forFrameCount: frameDelta)
            let endMs = cursorMs + max(1, segmentDurationMs)
            renderedSegments.append(MediaTimelineSegment(
                id: "tts-seg-\(String(format: "%04d", index + 1))",
                startMs: cursorMs,
                endMs: endMs,
                startChar: segment.startChar,
                endChar: segment.endChar,
                text: segment.text
            ))
            cursorMs = endMs
        }
        guard cursorMs > 0 else {
            throw SessionKitError.persistenceFailed("generated_text_audio_empty")
        }
        let chapters = Self.generatedChapters(from: renderedSegments)
        return (
            TranscriptTimeline(segments: renderedSegments, chapters: chapters, durationMs: cursorMs),
            cursorMs
        )
    }

    private func writeUtterance(
        _ text: String,
        synthesizer: AVSpeechSynthesizer,
        accumulator: AudioFileAccumulator
    ) throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if let voiceIdentifier,
           let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = configuredVoice
        }
        let semaphore = DispatchSemaphore(value: 0)
        let callbackState = SpeechWriteCallbackState()
        synthesizer.write(utterance) { buffer in
            callbackState.lock.lock()
            defer { callbackState.lock.unlock() }
            guard callbackState.isFinished == false else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
                callbackState.isFinished = true
                semaphore.signal()
                return
            }
            do {
                try accumulator.write(pcmBuffer)
            } catch {
                callbackState.error = error
                callbackState.isFinished = true
                semaphore.signal()
            }
        }
        if Thread.isMainThread {
            while true {
                callbackState.lock.lock()
                let isFinished = callbackState.isFinished
                callbackState.lock.unlock()
                if isFinished { break }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        } else {
            semaphore.wait()
        }
        if let error = callbackState.error {
            throw error
        }
    }

    private func resolvedOutputDirectory() throws -> URL {
        if let outputDirectory {
            return outputDirectory
        }
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appending(path: "SpokenMargins/GeneratedTextAudio", directoryHint: .isDirectory)
    }

    private static func generatedChapters(from segments: [MediaTimelineSegment]) -> [MediaTimelineChapter] {
        guard !segments.isEmpty else { return [] }
        let targetCount = min(12, max(1, Int((Double(segments.count) / 8.0).rounded(.up))))
        let stride = max(1, Int((Double(segments.count) / Double(targetCount)).rounded(.up)))
        return segments.enumerated().compactMap { index, segment in
            guard index % stride == 0 else { return nil }
            let title = segment.text
                .split(separator: " ")
                .prefix(7)
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,"))
            return MediaTimelineChapter(
                id: "ch-generated-audio-\(String(format: "%02d", (index / stride) + 1))",
                title: title.isEmpty ? "Chapter \((index / stride) + 1)" : title,
                startMs: segment.startMs,
                transcriptSegmentId: segment.id
            )
        }
    }
    #endif

    private static func textSegments(in text: String, maxSegmentCharacters: Int) -> [TextAudioSegment] {
        var segments: [TextAudioSegment] = []
        var fragment = ""
        var fragmentStart = 0
        for (offset, character) in text.enumerated() {
            if fragment.isEmpty {
                fragmentStart = offset
            }
            fragment.append(character)
            let shouldBreakAtSentence = ".!?".contains(character) && fragment.count >= 24
            let shouldBreakAtLength = fragment.count >= maxSegmentCharacters && character.isWhitespace
            let shouldHardBreak = fragment.count >= maxSegmentCharacters * 2
            if shouldBreakAtSentence || shouldBreakAtLength || shouldHardBreak {
                appendSegment(fragment, start: fragmentStart, to: &segments)
                fragment.removeAll(keepingCapacity: true)
            }
        }
        appendSegment(fragment, start: fragmentStart, to: &segments)
        return segments
    }

    private static func appendSegment(_ fragment: String, start: Int, to segments: inout [TextAudioSegment]) {
        let characters = Array(fragment)
        var lower = 0
        var upper = characters.count
        while lower < upper, characters[lower].isWhitespace {
            lower += 1
        }
        while upper > lower, characters[upper - 1].isWhitespace {
            upper -= 1
        }
        guard lower < upper else { return }
        let text = String(characters[lower..<upper])
        segments.append(TextAudioSegment(
            startChar: start + lower,
            endChar: start + upper,
            text: text
        ))
    }

    private static func cacheSignature(itemId: String, text: String, voiceIdentifier: String?, speechRate: Float, scope: String = "complete") -> String {
        var components = [
            "system-text-audio-v1",
            itemId,
            voiceIdentifier ?? "default",
            String(format: "%.4f", speechRate),
            text
        ]
        if scope != "complete" {
            components.append(scope)
        }
        let seed = components.joined(separator: "\u{1f}")
        return stableHash(seed)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func safePathComponent(_ value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(safe).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "item" : String(collapsed.prefix(64))
    }

    private struct TextAudioSegment: Sendable {
        var startChar: Int
        var endChar: Int
        var text: String
    }

    private enum TextAudioRenderScope {
        case complete
        case starter(targetDurationMs: Int)

        var cacheScope: String {
            switch self {
            case .complete:
                return "complete"
            case .starter(let targetDurationMs):
                return "starter-\(max(1_000, targetDurationMs))"
            }
        }

        var fileSuffix: String {
            switch self {
            case .complete:
                return ""
            case .starter:
                return "-starter"
            }
        }

        func segments(from segments: [TextAudioSegment], speechRate: Float) -> [TextAudioSegment] {
            switch self {
            case .complete:
                return segments
            case .starter(let targetDurationMs):
                return Self.starterSegments(from: segments, targetDurationMs: targetDurationMs, speechRate: speechRate)
            }
        }

        private static func starterSegments(from segments: [TextAudioSegment], targetDurationMs: Int, speechRate: Float) -> [TextAudioSegment] {
            guard let first = segments.first else { return [] }
            let rateFactor = max(0.5, min(2.0, Double(speechRate) / 0.5))
            let targetSeconds = max(5.0, Double(targetDurationMs) / 1_000.0)
            let targetCharacters = max(280, min(1_200, Int((targetSeconds * 15.0 * rateFactor).rounded())))
            var selected: [TextAudioSegment] = []
            var characterCount = 0
            for segment in segments {
                selected.append(segment)
                characterCount += segment.text.count
                if characterCount >= targetCharacters {
                    break
                }
            }
            return selected.isEmpty ? [first] : selected
        }
    }

    private struct CachedPreparedTextAudio: Codable {
        var signature: String
        var normalizedText: String
        var audioFileName: String
        var timeline: TranscriptTimeline
        var createdAt: Date
    }

    #if canImport(AVFoundation)
    private final class AudioFileAccumulator {
        let outputURL: URL
        var file: AVAudioFile?
        var sampleRate: Double?
        var totalFrames: AVAudioFramePosition = 0

        init(outputURL: URL) {
            self.outputURL = outputURL
        }

        func write(_ buffer: AVAudioPCMBuffer) throws {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: buffer.format.settings)
                sampleRate = buffer.format.sampleRate
            }
            try file?.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        }

        func milliseconds(forFrameCount frameCount: AVAudioFramePosition) -> Int {
            guard let sampleRate, sampleRate > 0 else { return 0 }
            return Int(((Double(frameCount) / sampleRate) * 1000).rounded())
        }
    }

    private final class SpeechWriteCallbackState {
        let lock = NSLock()
        var isFinished = false
        var error: Error?
    }
    #endif
}

struct SpeechPlaybackChunk: Equatable, Sendable {
    var sourceStart: Int
    var sourceEnd: Int
    var spokenText: String
    var spokenSourceOffsets: [Int]

    func sourceOffset(atSpokenUTF16Offset utf16Offset: Int) -> Int {
        guard !spokenSourceOffsets.isEmpty else { return sourceEnd }
        let clamped = max(0, min(utf16Offset, spokenText.utf16.count))
        let index = String.Index(utf16Offset: clamped, in: spokenText)
        let characterOffset = spokenText.distance(from: spokenText.startIndex, to: index)
        guard characterOffset < spokenSourceOffsets.count else { return sourceEnd }
        return spokenSourceOffsets[characterOffset]
    }
}

enum SpeechPlaybackPlanner {
    static func chunks(
        in source: String,
        from requestedOffset: Int,
        targetChunkCharacters: Int = 700
    ) -> [SpeechPlaybackChunk] {
        let characters = Array(source)
        let start = max(0, min(requestedOffset, characters.count))
        let target = max(240, targetChunkCharacters)
        var chunks: [SpeechPlaybackChunk] = []
        var fragment: [Character] = []
        var fragmentStart = start

        func appendFragment() {
            var lower = 0
            var upper = fragment.count
            while lower < upper, fragment[lower].isWhitespace { lower += 1 }
            while upper > lower, fragment[upper - 1].isWhitespace { upper -= 1 }
            guard lower < upper else {
                if !chunks.isEmpty {
                    chunks[chunks.count - 1].sourceEnd = fragmentStart + fragment.count
                }
                fragment.removeAll(keepingCapacity: true)
                return
            }
            let sourceStart = fragmentStart + lower
            let sourceEnd = fragmentStart + fragment.count
            let trimmed = String(fragment[lower..<upper])
            let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(trimmed)
            guard !normalized.text.isEmpty else {
                fragment.removeAll(keepingCapacity: true)
                return
            }
            chunks.append(SpeechPlaybackChunk(
                sourceStart: sourceStart,
                // Treat whitespace removed at the end of the fragment as
                // consumed source so the final chunk reaches document EOF.
                sourceEnd: sourceEnd,
                spokenText: normalized.text,
                spokenSourceOffsets: normalized.sourceOffsets.map { sourceStart + $0 }
            ))
            fragment.removeAll(keepingCapacity: true)
        }

        for offset in start..<characters.count {
            if fragment.isEmpty { fragmentStart = offset }
            let character = characters[offset]
            fragment.append(character)
            let previous = fragment.dropLast().last
            let paragraphBoundary = character == "\n" && previous == "\n" && fragment.count >= 24
            let sentenceBoundary = ".!?".contains(character) && fragment.count >= target / 2
            let lengthBoundary = fragment.count >= target && character.isWhitespace
            let hardBoundary = fragment.count >= target * 2
            if paragraphBoundary || sentenceBoundary || lengthBoundary || hardBoundary {
                appendFragment()
            }
        }
        appendFragment()
        return chunks
    }
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
    private var currentRangeLength = 0
    private var completedTargetId: String?
    private var playbackComplete = false
    private var pendingStartTargetId: String?
    private var startedTargetId: String?
    private var playbackStartFailure: String?
    private var paused = false
    private var voiceIdentifier: String?
    private var speechRate: Float
    private let readsSpeechSettingsAtPlayback: Bool
    #if canImport(AVFoundation)
    private weak var activeUtterance: AVSpeechUtterance?
    private var chunksByUtteranceId: [ObjectIdentifier: SpeechPlaybackChunk] = [:]
    private var finalUtteranceId: ObjectIdentifier?
    #endif

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

    public func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        speechRate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
    }

    public func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        #if canImport(AVFoundation)
        let source = preparedSourceText.isEmpty ? preparedSpeechText : preparedSourceText
        let chunks = SpeechPlaybackPlanner.chunks(in: source, from: charOffset)
        guard !chunks.isEmpty else {
            throw SessionKitError.invalidCommandForState("playback_text_empty")
        }
        if synthesizer.isSpeaking || paused || !chunksByUtteranceId.isEmpty {
            replaceSynthesizer()
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        lastTargetId = targetId
        lastStartOffset = charOffset
        currentOffset = chunks[0].sourceStart
        currentRangeLength = 0
        completedTargetId = nil
        playbackComplete = false
        pendingStartTargetId = targetId
        startedTargetId = nil
        playbackStartFailure = nil
        paused = false
        chunksByUtteranceId.removeAll(keepingCapacity: true)
        let mode = playbackSpeechPreviewMode()
        for chunk in chunks {
            let utterance = makeUtterance(chunk.spokenText, mode: mode)
            let identifier = ObjectIdentifier(utterance)
            chunksByUtteranceId[identifier] = chunk
            finalUtteranceId = identifier
            synthesizer.speak(utterance)
        }
        #else
        if preparedSpeechText.isEmpty {
            throw SessionKitError.invalidCommandForState("playback_text_empty")
        }
        #endif
    }

    public func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        if lastTargetId == targetId, let playbackStartFailure {
            return .failed(playbackStartFailure)
        }
        if startedTargetId == targetId {
            return .confirmed
        }
        if pendingStartTargetId == targetId {
            return .pending
        }
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking, lastTargetId == targetId {
            return .confirmed
        }
        #endif
        return .confirmed
    }

    public func preview(_ text: String, mode: SpeechPreviewMode) throws {
        #if canImport(AVFoundation)
        let textToSpeak = SpeechTextNormalizer.normalize(text)
        guard !textToSpeak.isEmpty else {
            throw SessionKitError.invalidCommandForState("preview_text_empty")
        }
        if synthesizer.isSpeaking || !chunksByUtteranceId.isEmpty { replaceSynthesizer() }
        resetPlaybackStateForPreview()
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
        if synthesizer.isSpeaking || !chunksByUtteranceId.isEmpty {
            paused = true
            replaceSynthesizer()
        }
        #endif
    }

    public func currentCharOffset() -> Int? {
        currentOffset
    }

    public func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentOffset else { return nil }
        let end = min(preparedSourceText.count, currentOffset + max(1, currentRangeLength))
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: lastTargetId,
            textStart: currentOffset,
            textEnd: end,
            anchorConfidence: .textRange
        )
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        playbackComplete && completedTargetId == targetId
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        replaceSynthesizer()
        paused = false
        playbackComplete = false
        completedTargetId = nil
        pendingStartTargetId = nil
        startedTargetId = nil
        playbackStartFailure = nil
        currentOffset = nil
        currentRangeLength = 0
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
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
        activeUtterance = nil
        chunksByUtteranceId.removeAll(keepingCapacity: true)
        finalUtteranceId = nil
        installSynthesizerDelegate()
    }

    private func resetPlaybackStateForPreview() {
        activeUtterance = nil
        chunksByUtteranceId.removeAll(keepingCapacity: true)
        finalUtteranceId = nil
        pendingStartTargetId = nil
        startedTargetId = nil
        playbackStartFailure = nil
        playbackComplete = false
        completedTargetId = nil
        paused = false
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
        didStart utterance: AVSpeechUtterance
    ) {
        activeUtterance = utterance
        if let chunk = chunksByUtteranceId[ObjectIdentifier(utterance)] {
            currentOffset = chunk.sourceStart
            currentRangeLength = 0
        }
        startedTargetId = lastTargetId
        pendingStartTargetId = nil
        playbackStartFailure = nil
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard let chunk = chunksByUtteranceId[ObjectIdentifier(utterance)] else { return }
        let start = chunk.sourceOffset(atSpokenUTF16Offset: characterRange.location)
        let end = chunk.sourceOffset(atSpokenUTF16Offset: characterRange.location + characterRange.length)
        currentOffset = start
        currentRangeLength = max(0, end - start)
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        guard let chunk = chunksByUtteranceId.removeValue(forKey: identifier) else { return }
        if activeUtterance === utterance {
            activeUtterance = nil
        }
        currentOffset = chunk.sourceEnd
        currentRangeLength = 0
        if finalUtteranceId == identifier {
            finalUtteranceId = nil
            completedTargetId = lastTargetId
            playbackComplete = true
        }
        pendingStartTargetId = nil
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let identifier = ObjectIdentifier(utterance)
        let wasPlaybackUtterance = chunksByUtteranceId.removeValue(forKey: identifier) != nil
        if activeUtterance === utterance {
            activeUtterance = nil
        }
        playbackComplete = false
        completedTargetId = nil
        if wasPlaybackUtterance, pendingStartTargetId == lastTargetId {
            playbackStartFailure = "speech_cancelled_before_start"
        }
        pendingStartTargetId = nil
    }
}
#endif

public final class PreparedAudioPlaybackClient: NSObject, AudioPlaybackClient, @unchecked Sendable {
    #if canImport(AVFoundation)
    private var player: AVAudioPlayer?
    #endif
    private var preparedFiles: [String: URL] = [:]
    private var durations: [String: Int] = [:]
    private var completedTargetId: String?
    private var playbackComplete = false
    private var activeTargetId: String?
    private var lastRequestedMediaTimeMs = 0
    private var playbackRate: Double = 1

    public override init() {
        super.init()
    }

    public func prepareAudioFile(targetId: String, fileURL: URL, durationMs: Int? = nil) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SessionKitError.persistenceFailed("prepared_audio_missing:\(fileURL.lastPathComponent)")
        }
        #if canImport(AVFoundation)
        let player = try AVAudioPlayer(contentsOf: fileURL)
        guard player.duration > 0 else {
            throw SessionKitError.persistenceFailed("prepared_audio_empty:\(fileURL.lastPathComponent)")
        }
        #endif
        preparedFiles[targetId] = fileURL
        if let durationMs {
            durations[targetId] = durationMs
        }
    }

    public func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    public func play(targetId: String) throws {
        try play(targetId: targetId, fromMediaTimeMs: 0)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId, fromMediaTimeMs: charOffset)
    }

    public func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        #if canImport(AVFoundation)
        guard let url = preparedFiles[targetId] else {
            throw SessionKitError.invalidCommandForState("prepared_audio_unavailable:\(targetId)")
        }
        if activeTargetId != targetId || player == nil {
            player?.stop()
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.delegate = self
            nextPlayer.enableRate = true
            nextPlayer.prepareToPlay()
            player = nextPlayer
            activeTargetId = targetId
        }
        #if os(iOS) || os(watchOS)
        try configurePreparedAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let offset = max(0, Double(mediaTimeMs) / 1000)
        if let player {
            player.currentTime = min(offset, player.duration)
            player.rate = Float(playbackRate)
            lastRequestedMediaTimeMs = max(0, Int((player.currentTime * 1000).rounded()))
            playbackComplete = false
            completedTargetId = nil
            guard player.play() else {
                throw SessionKitError.persistenceFailed("prepared_audio_playback_failed:\(targetId)")
            }
        }
        #else
        throw SessionKitError.persistenceFailed("prepared_audio_playback_unavailable")
        #endif
    }

    public func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        #if canImport(AVFoundation)
        guard let player else {
            lastRequestedMediaTimeMs = max(0, mediaTimeMs)
            return
        }
        let seconds = max(0, Double(mediaTimeMs) / 1000)
        player.currentTime = min(seconds, player.duration)
        lastRequestedMediaTimeMs = max(0, Int((player.currentTime * 1000).rounded()))
        #else
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        #endif
    }

    public func setPlaybackRate(_ rate: Double) throws {
        playbackRate = max(0.5, min(3.0, rate))
        #if canImport(AVFoundation)
        player?.enableRate = true
        if player?.isPlaying == true {
            player?.rate = Float(playbackRate)
        }
        #endif
    }

    public func currentMediaTimeMs() -> Int? {
        #if canImport(AVFoundation)
        guard let player else { return lastRequestedMediaTimeMs }
        return max(0, Int((player.currentTime * 1000).rounded()))
        #else
        return lastRequestedMediaTimeMs
        #endif
    }

    public func currentPlaybackDurationMs() -> Int? {
        guard let activeTargetId else { return nil }
        if let known = durations[activeTargetId] {
            return known
        }
        #if canImport(AVFoundation)
        guard let duration = player?.duration, duration.isFinite, duration > 0 else {
            return nil
        }
        let ms = Int((duration * 1000).rounded())
        durations[activeTargetId] = ms
        return ms
        #else
        return nil
        #endif
    }

    public func currentCharOffset() -> Int? {
        nil
    }

    public func currentPlaybackPosition() -> PlaybackPosition? {
        guard let activeTargetId else { return nil }
        return PlaybackPosition(
            targetType: .transcriptBackedMedia,
            targetId: activeTargetId,
            mediaTimeMs: currentMediaTimeMs(),
            durationMs: currentPlaybackDurationMs(),
            playbackRate: playbackRate,
            anchorConfidence: .mediaTime
        )
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        playbackComplete && completedTargetId == targetId
    }

    public func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        guard activeTargetId == targetId else { return .pending }
        #if canImport(AVFoundation)
        return player?.isPlaying == true ? .confirmed : .pending
        #else
        return .confirmed
        #endif
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        player?.pause()
        #endif
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        activeTargetId = nil
        playbackComplete = false
        completedTargetId = nil
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }

    #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
    private func configurePreparedAudioSession() throws {
        #if os(watchOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        #else
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        #endif
    }
    #endif
}

#if canImport(AVFoundation)
extension PreparedAudioPlaybackClient: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playbackComplete = flag
        completedTargetId = activeTargetId
    }
}
#endif

public final class AVPlayerStreamPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    #if canImport(AVFoundation)
    private var player: AVPlayer?
    private var completionObserver: NSObjectProtocol?
    private var timeObserverToken: Any?
    private var playerStateObservation: NSKeyValueObservation?
    #endif
    private let remoteCommandHandler: (@Sendable (CompactControlCommand, Int?, Double?) -> Void)?
    private var mediaContext: PlaybackMediaContext?
    private var activeTargetId: String?
    private var activePlaybackURL: URL?
    private var completedTargetId: String?
    private var playbackComplete = false
    private var lastRequestedMediaTimeMs = 0
    private var knownDurations: [String: Int] = [:]
    private var playbackRate: Double = 1
    private var paused = true
    private var preferredSkipBackSeconds: Int
    private var preferredSkipForwardSeconds: Int
    #if canImport(MediaPlayer) && os(iOS)
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    #endif

    public init(
        preferredSkipBackSeconds: Int = 15,
        preferredSkipForwardSeconds: Int = 15,
        remoteCommandHandler: (@Sendable (CompactControlCommand, Int?, Double?) -> Void)? = nil
    ) {
        self.preferredSkipBackSeconds = Self.validatedSkipSeconds(preferredSkipBackSeconds)
        self.preferredSkipForwardSeconds = Self.validatedSkipSeconds(preferredSkipForwardSeconds)
        self.remoteCommandHandler = remoteCommandHandler
        installRemoteCommandHandlers()
    }

    public func setPreferredSkipIntervals(backSeconds: Int, forwardSeconds: Int) {
        preferredSkipBackSeconds = Self.validatedSkipSeconds(backSeconds)
        preferredSkipForwardSeconds = Self.validatedSkipSeconds(forwardSeconds)
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipBackSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipForwardSeconds)]
        #endif
    }

    private static func validatedSkipSeconds(_ seconds: Int) -> Int {
        max(1, min(300, seconds))
    }

    deinit {
        removePlayerStateObserver()
        removeCompletionObserver()
        removeTimeObserver()
        removeRemoteCommandHandlers()
    }

    public func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        mediaContext = context
        if let context, let durationMs = context.durationMs {
            knownDurations[context.targetId] = durationMs
        }
        publishNowPlaying(isPlaying: !paused)
    }

    public func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    public func play(targetId: String) throws {
        try play(targetId: targetId, fromMediaTimeMs: 0)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId, fromMediaTimeMs: charOffset)
    }

    public func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        #if canImport(AVFoundation)
        let requestedURL = mediaContext?.targetId == targetId ? mediaContext?.playbackURL : nil
        guard let url = URL(string: requestedURL ?? targetId) else {
            throw SessionKitError.invalidCommandForState("stream_audio_invalid_url:\(requestedURL ?? targetId)")
        }
        if activeTargetId != targetId || activePlaybackURL != url || player == nil {
            removePlayerStateObserver()
            removeCompletionObserver()
            removeTimeObserver()
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            activeTargetId = targetId
            activePlaybackURL = url
            observeCompletion(for: item)
            installPlayerStateObserver()
            installTimeObserver()
        }
        #if os(iOS) || os(watchOS)
        try configureStreamAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let seconds = max(0, Double(mediaTimeMs) / 1000)
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        playbackComplete = false
        completedTargetId = nil
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        player?.rate = Float(playbackRate)
        paused = false
        publishNowPlaying(isPlaying: true)
        #else
        throw SessionKitError.persistenceFailed("stream_audio_playback_unavailable")
        #endif
    }

    public func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        #if canImport(AVFoundation)
        let seconds = max(0, Double(mediaTimeMs) / 1000)
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        guard let player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        publishNowPlaying(isPlaying: !paused)
        #else
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        #endif
    }

    public func setPlaybackRate(_ rate: Double) throws {
        playbackRate = max(0.5, min(3.0, rate))
        #if canImport(AVFoundation)
        if !paused {
            player?.rate = Float(playbackRate)
        }
        publishNowPlaying(isPlaying: !paused)
        #endif
    }

    public func currentPlaybackPosition() -> PlaybackPosition? {
        guard let activeTargetId else { return nil }
        let mediaTimeMs = currentMediaTimeMs()
        let chapterId = mediaTimeMs.flatMap { currentChapterId(mediaTimeMs: $0) }
        return PlaybackPosition(
            itemId: mediaContext?.itemId,
            targetType: mediaContext?.targetType ?? .transcriptBackedMedia,
            targetId: activeTargetId,
            mediaTimeMs: mediaTimeMs,
            durationMs: durationMs(for: activeTargetId),
            chapterId: chapterId,
            playbackRate: playbackRate,
            anchorConfidence: .mediaTime
        )
    }

    public func currentCharOffset() -> Int? {
        nil
    }

    public func currentMediaTimeMs() -> Int? {
        #if canImport(AVFoundation)
        guard let player else { return lastRequestedMediaTimeMs }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return lastRequestedMediaTimeMs }
        return max(0, Int((seconds * 1000).rounded()))
        #else
        return lastRequestedMediaTimeMs
        #endif
    }

    public func currentPlaybackDurationMs() -> Int? {
        guard let activeTargetId else { return nil }
        return durationMs(for: activeTargetId)
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        playbackComplete && completedTargetId == targetId
    }

    public func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        guard activeTargetId == targetId else { return .pending }
        #if canImport(AVFoundation)
        if let error = player?.currentItem?.error {
            return .failed(error.localizedDescription)
        }
        switch player?.timeControlStatus {
        case .playing:
            return .confirmed
        case .paused:
            return paused ? .pending : .pending
        case .waitingToPlayAtSpecifiedRate:
            return .pending
        case nil:
            return .pending
        @unknown default:
            return .pending
        }
        #else
        return .confirmed
        #endif
    }

    public func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        guard activeTargetId == targetId else { return .stopped }
        #if canImport(AVFoundation)
        if player?.currentItem?.error != nil {
            return .failed
        }
        switch player?.timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        case .paused:
            return playbackComplete ? .stopped : .paused
        case nil:
            return .stopped
        @unknown default:
            return nil
        }
        #else
        return paused ? .paused : .playing
        #endif
    }

    public func pause() throws {
        #if canImport(AVFoundation)
        player?.pause()
        paused = true
        publishNowPlaying(isPlaying: false)
        #endif
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        player?.pause()
        removePlayerStateObserver()
        player = nil
        removeCompletionObserver()
        removeTimeObserver()
        activeTargetId = nil
        activePlaybackURL = nil
        completedTargetId = nil
        playbackComplete = false
        paused = true
        clearNowPlaying()
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }

    private func durationMs(for targetId: String) -> Int? {
        if let known = knownDurations[targetId] {
            return known
        }
        if mediaContext?.targetId == targetId, let durationMs = mediaContext?.durationMs {
            knownDurations[targetId] = durationMs
            return durationMs
        }
        #if canImport(AVFoundation)
        guard let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0 else {
            return nil
        }
        let ms = Int((duration * 1000).rounded())
        knownDurations[targetId] = ms
        return ms
        #else
        return nil
        #endif
    }

    #if canImport(AVFoundation)
    private func observeCompletion(for item: AVPlayerItem) {
        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.playbackComplete = true
            self?.completedTargetId = self?.activeTargetId
            self?.paused = true
            self?.publishNowPlaying(isPlaying: false)
        }
    }

    private func removeCompletionObserver() {
        if let completionObserver {
            NotificationCenter.default.removeObserver(completionObserver)
            self.completionObserver = nil
        }
    }

    private func installTimeObserver() {
        guard let player, timeObserverToken == nil else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.publishNowPlaying(isPlaying: !self.paused)
        }
    }

    private func installPlayerStateObserver() {
        playerStateObservation?.invalidate()
        playerStateObservation = player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self else { return }
            switch player.timeControlStatus {
            case .playing:
                self.paused = false
                self.publishNowPlaying(isPlaying: true)
            case .paused:
                self.paused = true
                self.publishNowPlaying(isPlaying: false)
            case .waitingToPlayAtSpecifiedRate:
                self.paused = false
                self.publishNowPlaying(isPlaying: true)
            @unknown default:
                break
            }
        }
    }

    private func removePlayerStateObserver() {
        playerStateObservation?.invalidate()
        playerStateObservation = nil
    }

    private func removeTimeObserver() {
        guard let timeObserverToken else { return }
        player?.removeTimeObserver(timeObserverToken)
        self.timeObserverToken = nil
    }
    #else
    private func removePlayerStateObserver() {}
    private func removeCompletionObserver() {}
    private func removeTimeObserver() {}
    #endif

    private func currentChapterId(mediaTimeMs: Int) -> String? {
        mediaContext?.chapters
            .filter { $0.startMs <= mediaTimeMs }
            .sorted { $0.startMs < $1.startMs }
            .last?
            .id
    }

    private func publishNowPlaying(isPlaying: Bool) {
        #if canImport(MediaPlayer) && os(iOS)
        guard activeTargetId != nil || mediaContext != nil else { return }
        let targetId = activeTargetId ?? mediaContext?.targetId
        let durationSeconds = targetId.flatMap { durationMs(for: $0) }.map { max(0, Double($0) / 1000) }
        let elapsedSeconds = max(0, Double(currentMediaTimeMs() ?? lastRequestedMediaTimeMs) / 1000)
        let context = mediaContext
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: context?.title ?? "Spoken Margins",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: durationSeconds == nil
        ]
        if let subtitle = context?.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if let durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        if let targetId,
           let url = URL(string: targetId),
           url.scheme?.isEmpty == false {
            info[MPNowPlayingInfoPropertyAssetURL] = url
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        configureRemoteCommandAvailability(canSeek: durationSeconds != nil)
        #if canImport(UIKit)
        Task { @MainActor in
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
        #endif
    }

    private func clearNowPlaying() {
        #if canImport(MediaPlayer) && os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    private func installRemoteCommandHandlers() {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        removeRemoteCommandHandlers()

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipBackSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipForwardSeconds)]
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 2.0]
        configureRemoteCommandAvailability(canSeek: false)

        register(center.playCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.play) == true ? .success : .noSuchContent
        }
        register(center.pauseCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.pause) == true ? .success : .noSuchContent
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.togglePlayPause) == true ? .success : .noSuchContent
        }
        register(center.stopCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.pause) == true ? .success : .noSuchContent
        }
        register(center.skipBackwardCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.skipBack) == true ? .success : .noSuchContent
        }
        register(center.previousTrackCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.skipBack) == true ? .success : .noSuchContent
        }
        register(center.skipForwardCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.skipForward) == true ? .success : .noSuchContent
        }
        register(center.nextTrackCommand) { [weak self] _ in
            self?.dispatchRemoteCommand(.skipForward) == true ? .success : .noSuchContent
        }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let mediaTimeMs = max(0, Int((event.positionTime * 1000).rounded()))
            return self?.dispatchRemoteCommand(.seekToMediaTime, mediaTimeMs: mediaTimeMs) == true ? .success : .noSuchContent
        }
        register(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            return self?.dispatchRemoteCommand(.setPlaybackRate, playbackRate: Double(event.playbackRate)) == true ? .success : .noSuchContent
        }
        #endif
    }

    private func configureRemoteCommandAvailability(canSeek: Bool) {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = canSeek
        center.changePlaybackRateCommand.isEnabled = true
        #endif
    }

    @discardableResult
    private func dispatchRemoteCommand(_ command: CompactControlCommand, mediaTimeMs: Int? = nil, playbackRate: Double? = nil) -> Bool {
        guard activeTargetId != nil else { return false }
        remoteCommandHandler?(command, mediaTimeMs, playbackRate)
        return remoteCommandHandler != nil
    }

    #if canImport(MediaPlayer) && os(iOS)
    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, target))
    }

    private func removeRemoteCommandHandlers() {
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
        }
        remoteCommandTargets.removeAll()
    }
    #else
    private func removeRemoteCommandHandlers() {}
    #endif

    #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
    private func configureStreamAudioSession() throws {
        #if os(watchOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        #else
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        #endif
    }
    #endif
}

public final class RoutedAudioPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    private enum Route {
        case speech
        case media
    }

    private let speech: AudioPlaybackClient
    private let media: AudioPlaybackClient
    private var activeRoute: Route?

    public init(speech: AudioPlaybackClient, media: AudioPlaybackClient) {
        self.speech = speech
        self.media = media
    }

    public func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        try media.configureMediaContext(context)
        if context == nil {
            try speech.configureMediaContext(nil)
        }
    }

    public func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        try speech.configureSpeechSettings(voiceIdentifier: voiceIdentifier, rate: rate)
    }

    public func prepareSpeechText(_ text: String) throws -> String {
        try speech.prepareSpeechText(text)
    }

    public func play(targetId: String) throws {
        activeRoute = .speech
        try speech.play(targetId: targetId)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        activeRoute = .speech
        try media.stop()
        try speech.play(targetId: targetId, from: charOffset)
    }

    public func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeRoute = .media
        try speech.stop()
        try media.play(targetId: targetId, fromMediaTimeMs: mediaTimeMs)
    }

    public func currentPlaybackPosition() -> PlaybackPosition? {
        switch activeRoute {
        case .speech:
            return speech.currentPlaybackPosition()
        case .media:
            return media.currentPlaybackPosition()
        case nil:
            return media.currentPlaybackPosition() ?? speech.currentPlaybackPosition()
        }
    }

    public func currentCharOffset() -> Int? {
        activeRoute == .speech ? speech.currentCharOffset() : nil
    }

    public func currentMediaTimeMs() -> Int? {
        activeRoute == .media ? media.currentMediaTimeMs() : nil
    }

    public func currentPlaybackDurationMs() -> Int? {
        activeRoute == .media ? media.currentPlaybackDurationMs() : nil
    }

    public func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        activeRoute = .media
        try media.seek(toMediaTimeMs: mediaTimeMs)
    }

    public func setPlaybackRate(_ rate: Double) throws {
        switch activeRoute {
        case .media:
            try media.setPlaybackRate(rate)
        case .speech:
            try speech.setPlaybackRate(rate)
        case nil:
            try media.setPlaybackRate(rate)
            try speech.setPlaybackRate(rate)
        }
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        speech.isPlaybackComplete(targetId: targetId) || media.isPlaybackComplete(targetId: targetId)
    }

    public func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        switch activeRoute {
        case .speech:
            return speech.playbackStartStatus(targetId: targetId)
        case .media:
            return media.playbackStartStatus(targetId: targetId)
        case nil:
            let mediaStatus = media.playbackStartStatus(targetId: targetId)
            if mediaStatus == .confirmed {
                return mediaStatus
            }
            return speech.playbackStartStatus(targetId: targetId)
        }
    }

    public func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        switch activeRoute {
        case .speech:
            return speech.playbackTransportState(targetId: targetId)
        case .media:
            return media.playbackTransportState(targetId: targetId)
        case nil:
            return media.playbackTransportState(targetId: targetId)
                ?? speech.playbackTransportState(targetId: targetId)
        }
    }

    public func pause() throws {
        switch activeRoute {
        case .speech:
            try speech.pause()
        case .media:
            try media.pause()
        case nil:
            try speech.pause()
            try media.pause()
        }
    }

    public func stop() throws {
        try speech.stop()
        try media.stop()
        activeRoute = nil
    }
}

public final class SystemRecordingClient: RecordingClient {
    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    #endif
    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let deactivateSessionOnFinish: Bool

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default, deactivateSessionOnFinish: Bool = false) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.deactivateSessionOnFinish = deactivateSessionOnFinish
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
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .duckOthers])
        #else
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        #endif
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
        if deactivateSessionOnFinish {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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

public final class SystemSourceTranscriptionClient: SourceTranscriptionClient, @unchecked Sendable {
    private struct SourceAudioChunk {
        var url: URL
        var offsetMs: Int
        var index: Int
    }

    public init() {}

    public func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        #if canImport(Speech) && canImport(AVFoundation)
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw SessionKitError.persistenceFailed("speech_recognition_not_authorized")
        }
        let localURL = try await localAudioURL(for: url, itemId: itemId)
        guard localURL.isFileURL, FileManager.default.fileExists(atPath: localURL.path) else {
            throw SessionKitError.persistenceFailed("source_audio_file_missing")
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        let chunks = try await audioChunks(for: localURL, itemId: itemId, durationMs: durationMs)
        var stitchedSegments: [MediaTimelineSegment] = []
        var stitchedChapters: [MediaTimelineChapter] = []
        var stitchedDurationMs = durationMs
        for chunk in chunks {
            let timeline = try await transcribeChunk(chunk, itemId: itemId, recognizer: recognizer, sourceDurationMs: durationMs)
            let offset = offsetTimeline(timeline, chunk: chunk)
            stitchedSegments.append(contentsOf: offset.segments)
            stitchedChapters.append(contentsOf: offset.chapters)
            stitchedDurationMs = max(stitchedDurationMs ?? 0, offset.durationMs ?? 0)
        }
        return TranscriptTimeline(
            segments: stitchedSegments.sorted { $0.startMs < $1.startMs },
            chapters: stitchedChapters.sorted { $0.startMs < $1.startMs },
            durationMs: stitchedDurationMs
        )
        #else
        throw SessionKitError.persistenceFailed("speech_recognition_unavailable")
        #endif
    }

    public func transcribeSourceAudioWindow(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> TranscriptTimeline {
        #if canImport(Speech) && canImport(AVFoundation)
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw SessionKitError.persistenceFailed("speech_recognition_not_authorized")
        }
        let localURL = try await localAudioURL(for: url, itemId: itemId)
        guard localURL.isFileURL, FileManager.default.fileExists(atPath: localURL.path) else {
            throw SessionKitError.persistenceFailed("source_audio_file_missing")
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        let asset = AVURLAsset(url: localURL)
        let loadedDuration = try await asset.load(.duration)
        let loadedDurationMs = Int((max(0, CMTimeGetSeconds(loadedDuration)) * 1000).rounded())
        let effectiveDurationMs = durationMs ?? loadedDurationMs
        let startMs = max(0, anchorMediaTimeMs - windowBeforeMs)
        let endMs = min(max(startMs + 1, effectiveDurationMs), anchorMediaTimeMs + windowAfterMs)
        let lengthMs = max(1, endMs - startMs)
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appending(path: "SourceAudioTranscriptionWindows/\(itemId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chunkURL = directory.appending(path: "window-\(anchorMediaTimeMs).m4a")
        if !FileManager.default.fileExists(atPath: chunkURL.path) {
            try await exportChunk(asset: asset, offsetMs: startMs, lengthMs: lengthMs, outputURL: chunkURL)
        }
        let chunk = SourceAudioChunk(url: chunkURL, offsetMs: startMs, index: 0)
        let timeline = try await transcribeChunk(chunk, itemId: itemId, recognizer: recognizer, sourceDurationMs: lengthMs)
        let offset = offsetTimeline(timeline, chunk: chunk)
        return TranscriptTimeline(
            segments: offset.segments.sorted { $0.startMs < $1.startMs },
            chapters: offset.chapters.sorted { $0.startMs < $1.startMs },
            durationMs: durationMs ?? max(effectiveDurationMs, offset.durationMs ?? 0)
        )
        #else
        throw SessionKitError.persistenceFailed("speech_recognition_unavailable")
        #endif
    }

    #if canImport(Speech) && canImport(AVFoundation)
    private func transcribeChunk(
        _ chunk: SourceAudioChunk,
        itemId: String,
        recognizer: SFSpeechRecognizer,
        sourceDurationMs: Int?
    ) async throws -> TranscriptTimeline {
        let request = SFSpeechURLRecognitionRequest(url: chunk.url)
        request.shouldReportPartialResults = false
        if #available(iOS 13.0, macOS 10.15, *) {
            request.requiresOnDeviceRecognition = false
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptTimeline, Error>) in
            var didFinish = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !didFinish {
                    didFinish = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal, !didFinish else { return }
                didFinish = true
                continuation.resume(returning: Self.timeline(from: result.bestTranscription, itemId: itemId, durationMs: sourceDurationMs))
            }
        }
    }

    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func audioChunks(for localURL: URL, itemId: String, durationMs: Int?) async throws -> [SourceAudioChunk] {
        let asset = AVURLAsset(url: localURL)
        let duration = try await asset.load(.duration)
        let loadedDurationMs = Int((max(0, CMTimeGetSeconds(duration)) * 1000).rounded())
        let effectiveDurationMs = durationMs ?? loadedDurationMs
        let chunkLengthMs = 10 * 60 * 1000
        guard effectiveDurationMs > chunkLengthMs else {
            return [SourceAudioChunk(url: localURL, offsetMs: 0, index: 0)]
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appending(path: "SourceAudioTranscriptionChunks/\(itemId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var chunks: [SourceAudioChunk] = []
        var offsetMs = 0
        var index = 0
        while offsetMs < effectiveDurationMs {
            let lengthMs = min(chunkLengthMs, effectiveDurationMs - offsetMs)
            let chunkURL = directory.appending(path: "chunk-\(String(format: "%04d", index)).m4a")
            if !FileManager.default.fileExists(atPath: chunkURL.path) {
                try await exportChunk(asset: asset, offsetMs: offsetMs, lengthMs: lengthMs, outputURL: chunkURL)
            }
            chunks.append(SourceAudioChunk(url: chunkURL, offsetMs: offsetMs, index: index))
            offsetMs += lengthMs
            index += 1
        }
        return chunks
    }

    private func exportChunk(asset: AVURLAsset, offsetMs: Int, lengthMs: Int, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SessionKitError.persistenceFailed("source_audio_chunk_exporter_unavailable")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: Double(offsetMs) / 1000, preferredTimescale: 600),
            duration: CMTime(seconds: Double(lengthMs) / 1000, preferredTimescale: 600)
        )
        try await exporter.export(to: outputURL, as: .m4a)
    }

    private func offsetTimeline(_ timeline: TranscriptTimeline, chunk: SourceAudioChunk) -> TranscriptTimeline {
        let prefix = "chunk-\(String(format: "%04d", chunk.index))"
        let segments = timeline.segments.map { segment in
            MediaTimelineSegment(
                id: "\(prefix)-\(segment.id)",
                startMs: chunk.offsetMs + segment.startMs,
                endMs: chunk.offsetMs + segment.endMs,
                startChar: segment.startChar,
                endChar: segment.endChar,
                text: segment.text
            )
        }
        let chapters = timeline.chapters.map { chapter in
            MediaTimelineChapter(
                id: "\(prefix)-\(chapter.id)",
                title: chapter.title,
                description: chapter.description,
                startMs: chunk.offsetMs + chapter.startMs,
                transcriptSegmentId: "\(prefix)-\(chapter.transcriptSegmentId)"
            )
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: chapters,
            durationMs: timeline.durationMs.map { chunk.offsetMs + $0 }
        )
    }

    private func localAudioURL(for url: URL, itemId: String) async throws -> URL {
        if url.isFileURL {
            return url
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SessionKitError.persistenceFailed("source_audio_url_unsupported")
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches.appending(path: "SourceAudioTranscription", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extensionName = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let destination = directory.appending(path: "\(itemId).\(extensionName)")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let (downloadedURL, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: destination)
        return destination
    }

    private static func timeline(from transcription: SFTranscription, itemId: String, durationMs: Int?) -> TranscriptTimeline {
        let segments = transcription.segments.enumerated().compactMap { index, segment -> MediaTimelineSegment? in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let startMs = max(0, Int((segment.timestamp * 1000).rounded()))
            let measuredDurationMs = max(1, Int((segment.duration * 1000).rounded()))
            return MediaTimelineSegment(
                id: "seg-\(String(format: "%04d", index + 1))",
                startMs: startMs,
                endMs: max(startMs + measuredDurationMs, startMs + 1),
                text: text
            )
        }
        if !segments.isEmpty {
            return TranscriptTimeline(
                segments: segments,
                chapters: generatedChapters(from: segments),
                durationMs: durationMs ?? segments.map(\.endMs).max()
            )
        }
        let fallback = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else {
            return TranscriptTimeline(segments: [], chapters: [], durationMs: durationMs)
        }
        let segment = MediaTimelineSegment(
            id: "seg-0001",
            startMs: 0,
            endMs: max(1, durationMs ?? 1),
            text: fallback
        )
        return TranscriptTimeline(
            segments: [segment],
            chapters: [MediaTimelineChapter(id: "ch-transcript-01", title: "Transcript", startMs: 0, transcriptSegmentId: segment.id)],
            durationMs: durationMs
        )
    }

    private static func generatedChapters(from segments: [MediaTimelineSegment]) -> [MediaTimelineChapter] {
        guard !segments.isEmpty else { return [] }
        let stride = max(1, Int((Double(segments.count) / 8.0).rounded(.up)))
        return segments.enumerated().compactMap { index, segment in
            guard index % stride == 0 else { return nil }
            let title = segment.text
                .split(separator: " ")
                .prefix(6)
                .joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,"))
            return MediaTimelineChapter(
                id: "ch-transcript-\(String(format: "%02d", (index / stride) + 1))",
                title: title.isEmpty ? "Chapter \((index / stride) + 1)" : title,
                startMs: segment.startMs,
                transcriptSegmentId: segment.id
            )
        }
    }
    #endif
}
