import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(MediaPlayer)
import MediaPlayer
#endif

#if canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
import MediaToolbox
import ShazamKit
#endif

#if canImport(Speech)
import Speech
#endif

#if canImport(UIKit)
import UIKit
#endif

public func systemSpeechTranscriptionEngineDescription() -> String {
    #if canImport(Speech) && canImport(AVFoundation)
    if #available(iOS 26.0, macOS 26.0, *) {
        return SpeechTranscriber.isAvailable
            ? "speech_analyzer_long_form"
            : "legacy_on_device_silence_segmented"
    }
    return "legacy_on_device_silence_segmented"
    #else
    return "unavailable"
    #endif
}

#if canImport(Speech)
/// Collects the ordered, finalized passages emitted by SpeechAnalyzer.
///
/// SpeechTranscriber final results are additive passages. They are not competing
/// hypotheses, so choosing the longest result (the legacy recognizer behavior)
/// would silently discard everything except one passage from a long recording.
struct SpeechAnalyzerFinalResultAccumulator {
    private(set) var transcript = ""
    private(set) var resultCount = 0

    mutating func record(_ passage: String) {
        guard !passage.isEmpty else { return }
        transcript.append(passage)
        resultCount += 1
    }

    var normalizedTranscript: String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SpeechAudioChunkRange: Equatable {
    var startMs: Int
    var lengthMs: Int
}

struct SpeechAudioSilenceRange: Equatable {
    var startMs: Int
    var endMs: Int

    var midpointMs: Int { startMs + ((endMs - startMs) / 2) }
}

/// Plans non-overlapping legacy-recognizer inputs. A sustained silence nearest
/// the preferred boundary wins, while the hard limit prevents an unexpectedly
/// quiet or continuous recording from creating an unbounded request.
func silenceAwareSpeechAudioChunkRanges(
    durationMs: Int,
    silenceRanges: [SpeechAudioSilenceRange],
    preferredChunkMs: Int = 30_000,
    maximumChunkMs: Int = 42_000,
    minimumChunkMs: Int = 5_000
) -> [SpeechAudioChunkRange] {
    guard durationMs > 0 else { return [] }
    guard durationMs > maximumChunkMs else {
        return [SpeechAudioChunkRange(startMs: 0, lengthMs: durationMs)]
    }

    var ranges: [SpeechAudioChunkRange] = []
    var startMs = 0
    while durationMs - startMs > maximumChunkMs {
        let earliestBoundary = startMs + minimumChunkMs
        let latestBoundary = min(durationMs, startMs + maximumChunkMs)
        let preferredBoundary = min(latestBoundary, startMs + preferredChunkMs)
        let silenceBoundary = silenceRanges
            .map(\.midpointMs)
            .filter { $0 >= earliestBoundary && $0 <= latestBoundary }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs - preferredBoundary)
                let rhsDistance = abs(rhs - preferredBoundary)
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            }
        let boundary = silenceBoundary ?? preferredBoundary
        ranges.append(SpeechAudioChunkRange(startMs: startMs, lengthMs: boundary - startMs))
        startMs = boundary
    }
    ranges.append(SpeechAudioChunkRange(startMs: startMs, lengthMs: durationMs - startMs))
    return ranges
}

#if canImport(AVFoundation)
func sustainedSilenceRanges(
    in url: URL,
    analysisWindowMs: Int = 50,
    minimumSilenceMs: Int = 650
) throws -> [SpeechAudioSilenceRange] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.sampleRate > 0,
          format.commonFormat == .pcmFormatFloat32,
          !format.isInterleaved else {
        return []
    }
    let windowFrameCount = max(1, Int((format.sampleRate * Double(analysisWindowMs) / 1000).rounded()))
    let bufferFrameCount = AVAudioFrameCount(max(windowFrameCount, 8_192))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrameCount) else {
        return []
    }

    var windowEnergy = 0.0
    var framesInWindow = 0
    var decibels: [Double] = []
    while file.framePosition < file.length {
        let remaining = file.length - file.framePosition
        let requestedFrames = AVAudioFrameCount(min(AVAudioFramePosition(bufferFrameCount), remaining))
        try file.read(into: buffer, frameCount: requestedFrames)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { break }
        guard let channels = buffer.floatChannelData else { return [] }
        let channelCount = Int(format.channelCount)
        for frame in 0..<frameLength {
            var frameEnergy = 0.0
            for channel in 0..<channelCount {
                let sample = Double(channels[channel][frame])
                frameEnergy += sample * sample
            }
            windowEnergy += frameEnergy / Double(max(1, channelCount))
            framesInWindow += 1
            if framesInWindow == windowFrameCount {
                let rms = sqrt(windowEnergy / Double(framesInWindow))
                decibels.append(rms > 0 ? 20 * log10(rms) : -100)
                windowEnergy = 0
                framesInWindow = 0
            }
        }
    }
    if framesInWindow > 0 {
        let rms = sqrt(windowEnergy / Double(framesInWindow))
        decibels.append(rms > 0 ? 20 * log10(rms) : -100)
    }
    guard decibels.count >= 2 else { return [] }

    let sorted = decibels.sorted()
    let quiet = sorted[Int(Double(sorted.count - 1) * 0.10)]
    let loud = sorted[Int(Double(sorted.count - 1) * 0.90)]
    // A nearly uniform recording has no defensible silence/speech separation.
    guard loud - quiet >= 8 else { return [] }
    let threshold = quiet + min(14, max(6, (loud - quiet) * 0.35))
    let minimumWindows = max(1, Int(ceil(Double(minimumSilenceMs) / Double(analysisWindowMs))))

    var ranges: [SpeechAudioSilenceRange] = []
    var silenceStartIndex: Int?
    for (index, level) in decibels.enumerated() {
        if level <= threshold {
            silenceStartIndex = silenceStartIndex ?? index
        } else if let start = silenceStartIndex {
            if index - start >= minimumWindows {
                ranges.append(SpeechAudioSilenceRange(
                    startMs: start * analysisWindowMs,
                    endMs: index * analysisWindowMs
                ))
            }
            silenceStartIndex = nil
        }
    }
    if let start = silenceStartIndex, decibels.count - start >= minimumWindows {
        ranges.append(SpeechAudioSilenceRange(
            startMs: start * analysisWindowMs,
            endMs: decibels.count * analysisWindowMs
        ))
    }
    return ranges
}
#endif

#if canImport(AVFoundation)
@available(iOS 26.0, macOS 26.0, *)
struct LongFormSpeechTimedText: Sendable {
    var text: String
    var startMs: Int
    var endMs: Int
}

@available(iOS 26.0, macOS 26.0, *)
struct LongFormSpeechPassage: Sendable {
    var text: String
    var startMs: Int
    var endMs: Int
    var timedText: [LongFormSpeechTimedText]
}

@available(iOS 26.0, macOS 26.0, *)
func transcribeLongFormSpeechFile(at url: URL) async throws -> [LongFormSpeechPassage] {
    guard SpeechTranscriber.isAvailable else {
        throw SessionKitError.persistenceFailed("long_form_speech_transcriber_unavailable")
    }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
        throw SessionKitError.persistenceFailed(
            "long_form_speech_locale_unsupported(locale=\(Locale.current.identifier))"
        )
    }
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )
    if let installationRequest = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber]
    ) {
        try await installationRequest.downloadAndInstall()
    }

    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: url)
    } catch {
        throw SessionKitError.persistenceFailed("long_form_audio_file_unreadable")
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    // A cancelled task must stop the analyzer however far it got: the queue's timeout cancels this task, and the slot
    // comes back only once this function returns (#1037). `analyzeSequence` can return while recognition still runs,
    // so the handler covers finalization and the wait for results too. `downloadAndInstall()` above relies on Swift
    // cancellation alone.
    return try await withTaskCancellationHandler {
        async let passages = collectLongFormSpeechPassages(from: transcriber)
        do {
            let analyzedThrough = try await analyzer.analyzeSequence(from: audioFile)
            try Task.checkCancellation()
            if let lastSample = analyzedThrough {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            let completed = try await passages
            try Task.checkCancellation()
            guard !completed.isEmpty else {
                throw SessionKitError.persistenceFailed("long_form_speech_transcript_empty")
            }
            return completed
        } catch {
            await analyzer.cancelAndFinishNow()
            _ = try? await passages
            throw error
        }
    } onCancel: {
        Task { await analyzer.cancelAndFinishNow() }
    }
}

@available(iOS 26.0, macOS 26.0, *)
func longFormSpeechTranscriptionIsSupported() async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    return await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) != nil
}

@available(iOS 26.0, macOS 26.0, *)
private func collectLongFormSpeechPassages(
    from transcriber: SpeechTranscriber
) async throws -> [LongFormSpeechPassage] {
    var passages: [LongFormSpeechPassage] = []
    for try await result in transcriber.results {
        guard result.isFinal else { continue }
        let passageText = String(result.text.characters)
        let passageStartMs = max(0, Int((CMTimeGetSeconds(result.range.start) * 1000).rounded()))
        let passageDurationMs = max(1, Int((CMTimeGetSeconds(result.range.duration) * 1000).rounded()))
        let timedText = result.text.runs.compactMap { run -> LongFormSpeechTimedText? in
            let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let timeRange = run.audioTimeRange else { return nil }
            let startMs = max(0, Int((CMTimeGetSeconds(timeRange.start) * 1000).rounded()))
            let durationMs = max(1, Int((CMTimeGetSeconds(timeRange.duration) * 1000).rounded()))
            return LongFormSpeechTimedText(text: text, startMs: startMs, endMs: startMs + durationMs)
        }
        passages.append(LongFormSpeechPassage(
            text: passageText,
            startMs: passageStartMs,
            endMs: passageStartMs + passageDurationMs,
            timedText: timedText
        ))
    }
    return passages
}
#endif

func makeOnDeviceSpeechRecognitionRequest(url: URL) -> SFSpeechURLRecognitionRequest {
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.shouldReportPartialResults = false
    if #available(iOS 13.0, macOS 10.15, *) {
        request.requiresOnDeviceRecognition = true
    }
    return request
}
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

    /// Renders on a serial background queue and hands back the result. The synchronous
    /// `prepareTextAudio` is for threads that may block: `AVSpeechSynthesizer.write` can hold its caller for
    /// seconds, so a call from the main actor froze the app for each scene summary (#2100). Serial, so
    /// renders queue behind one another instead of piling up blocked threads.
    public func prepareTextAudioOffMainThread(itemId: String, title: String, text: String) async throws -> PreparedTextAudio? {
        try await Self.runOffMainThread { try self.prepareTextAudio(itemId: itemId, title: title, text: text) }
    }

    static let renderQueue = DispatchQueue(label: "SessionKitAudio.SystemTextAudioPreparationClient.render", qos: .utility)

    static func runOffMainThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            renderQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    public func prepareStarterTextAudio(itemId: String, title: String, text: String, targetDurationMs: Int = 30_000) throws -> PreparedTextAudio? {
        try prepareTextAudio(itemId: itemId, title: title, text: text, scope: .starter(targetDurationMs: targetDurationMs))
    }

    private func prepareTextAudio(itemId: String, title: String, text: String, scope: TextAudioRenderScope) throws -> PreparedTextAudio? {
        #if canImport(AVFoundation)
        let normalizedText = SpeechTextNormalizer.projectForSystemSpeech(text).text
        guard !normalizedText.isEmpty else { return nil }
        guard SpeechTextNormalizer.isSystemSpeechSafe(normalizedText) else {
            throw SessionKitError.persistenceFailed("system_speech_projection_unsafe")
        }
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
        guard SpeechTextNormalizer.isSystemSpeechSafe(text) else {
            throw SessionKitError.persistenceFailed("system_speech_utterance_unsafe")
        }
        // A render waits on the synthesizer, so it never runs on the main thread. It used to spin a nested
        // run loop here, which let taps run model code in the middle of another model method (#2100).
        guard !Thread.isMainThread else {
            throw SessionKitError.persistenceFailed("system_speech_render_on_main_thread")
        }
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
        semaphore.wait()
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
            "system-text-audio-v2-safe-speech",
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
            let rateFactor = max(0.25, min(2.0, Double(speechRate) / 0.5))
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
        // System-speech projection guarantees that every Character occupies
        // exactly one UTF-16 code unit, so every clamped AVSpeech marker is a
        // valid Swift String boundary.
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
        let sourceCharacters = Array(source)
        let start = max(0, min(requestedOffset, sourceCharacters.count))
        let remainingSource = String(sourceCharacters[start...])
        let projection = SpeechTextNormalizer.projectForSystemSpeech(remainingSource)
        let characters = Array(projection.text)
        guard !characters.isEmpty else { return [] }
        let sourceOffsets = projection.sourceOffsets.map { start + $0 }
        let target = max(240, targetChunkCharacters)
        var chunks: [SpeechPlaybackChunk] = []
        var fragmentStart = 0

        func appendFragment(through end: Int) {
            guard fragmentStart < end else { return }
            let spokenText = String(characters[fragmentStart..<end])
            let spokenSourceOffsets = Array(sourceOffsets[fragmentStart..<end])
            guard let sourceStart = spokenSourceOffsets.first,
                  let finalSourceOffset = spokenSourceOffsets.last else { return }
            chunks.append(SpeechPlaybackChunk(
                sourceStart: sourceStart,
                sourceEnd: min(sourceCharacters.count, finalSourceOffset + 1),
                spokenText: spokenText,
                spokenSourceOffsets: spokenSourceOffsets
            ))
            fragmentStart = end
        }

        for offset in characters.indices {
            let character = characters[offset]
            let fragmentLength = offset - fragmentStart + 1
            let sentenceBoundary = ".!?".contains(character) && fragmentLength >= target / 2
            let lengthBoundary = fragmentLength >= target && character.isWhitespace
            let hardBoundary = fragmentLength >= target * 2
            if sentenceBoundary || lengthBoundary || hardBoundary {
                appendFragment(through: offset + 1)
            }
        }
        appendFragment(through: characters.count)
        for index in chunks.indices.dropLast() {
            chunks[index].sourceEnd = chunks[index + 1].sourceStart
        }
        chunks[chunks.count - 1].sourceEnd = sourceCharacters.count
        return chunks
    }
}

/// A voice that can say it is still moving through its words where its place in the source text
/// stands still, as it does while speaking a citation list expanded from one bracket (#432 audit).
public protocol SpokenProgressReporting: AnyObject {
    /// Grows each time the voice starts another word; nil when the voice can't tell.
    func spokenProgress() -> Int?
}

public final class SystemSpeechPlaybackClient: NSObject, AudioPlaybackClient, SpokenProgressReporting, @unchecked Sendable {
    #if canImport(AVFoundation)
    private var synthesizer = AVSpeechSynthesizer()
    #endif
    private var preparedSourceText = ""
    private var preparedSpeechText = ""
    private var lastTargetId: String?
    private var lastStartOffset = 0
    private var currentOffset: Int?
    private var currentRangeLength = 0
    private var spokenRanges = 0
    private var completedTargetId: String?
    private var playbackComplete = false
    private var pendingStartTargetId: String?
    private var startedTargetId: String?
    private var playbackStartFailure: String?
    private var paused = false
    private var voiceIdentifier: String?
    /// The listener's speed as `multiplier × 0.5` (the app's stored "speechRate" units), not an
    /// `AVSpeechUtterance.rate`: `SpeechRateRule` converts it when an utterance is made (I14).
    private var speechRate: Float
    private var hasExplicitSpeechRate = false
    private var mixesWithOtherAudio = false
    private var lowersBackgroundAudio = false
    private var playbackVolume: Float = 1
    private let readsSpeechSettingsAtPlayback: Bool
    private let isVoiceAvailable: (String) -> Bool
    #if canImport(AVFoundation)
    private weak var activeUtterance: AVSpeechUtterance?
    private var chunksByUtteranceId: [ObjectIdentifier: SpeechPlaybackChunk] = [:]
    private var finalUtteranceId: ObjectIdentifier?
    /// Hands a narration utterance to the synthesizer. Tests replace it to keep the synthesizer and
    /// the utterance, then deliver the delegate callbacks themselves (#1129).
    var speakNarration: (AVSpeechSynthesizer, AVSpeechUtterance) -> Void = { $0.speak($1) }
    #endif

    public override init() {
        self.voiceIdentifier = nil
        self.speechRate = AVSpeechUtteranceDefaultSpeechRate
        self.readsSpeechSettingsAtPlayback = true
        self.isVoiceAvailable = { AVSpeechSynthesisVoice(identifier: $0) != nil }
        super.init()
        #if canImport(AVFoundation)
        installSynthesizerDelegate()
        #endif
    }

    public init(
        voiceIdentifier: String? = nil,
        speechRate: Float = AVSpeechUtteranceDefaultSpeechRate,
        isVoiceAvailable: @escaping (String) -> Bool = { AVSpeechSynthesisVoice(identifier: $0) != nil }
    ) {
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        self.speechRate = speechRate
        self.readsSpeechSettingsAtPlayback = false
        self.isVoiceAvailable = isVoiceAvailable
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
        let normalized = SpeechTextNormalizer.projectForSystemSpeech(text).text
        preparedSpeechText = normalized
        return normalized
    }

    public func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        speechRate = Float(SpeechRateRule.multiplier(forStoredRate: rate)) * SpeechRateRule.systemDefaultRate
        hasExplicitSpeechRate = true
    }

    public func setPlaybackRate(_ rate: Double) throws {
        let updatedRate = Float(SpeechRateRule.clampedMultiplier(rate)) * SpeechRateRule.systemDefaultRate
        hasExplicitSpeechRate = true
        guard speechRate != updatedRate else { return }
        speechRate = updatedRate
        #if canImport(AVFoundation)
        guard synthesizer.isSpeaking,
              !paused,
              let targetId = lastTargetId else { return }
        let restartOffset = currentOffset ?? lastStartOffset
        try play(targetId: targetId, from: restartOffset)
        #endif
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
        guard chunks.allSatisfy({ SpeechTextNormalizer.isSystemSpeechSafe($0.spokenText) }) else {
            throw SessionKitError.invalidCommandForState("system_speech_projection_unsafe")
        }
        if synthesizer.isSpeaking || paused || !chunksByUtteranceId.isEmpty {
            replaceSynthesizer()
        }
        #if os(iOS)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(
            options: PlaybackAudioSessionPolicy.options(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio)
        )
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
        let mode = try narrationMode()
        for chunk in chunks {
            let utterance = makeUtterance(chunk.spokenText, mode: mode)
            let identifier = ObjectIdentifier(utterance)
            chunksByUtteranceId[identifier] = chunk
            finalUtteranceId = identifier
            speakNarration(synthesizer, utterance)
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
        let textToSpeak = SpeechTextNormalizer.projectForSystemSpeech(text).text
        guard !textToSpeak.isEmpty else {
            throw SessionKitError.invalidCommandForState("preview_text_empty")
        }
        if synthesizer.isSpeaking || !chunksByUtteranceId.isEmpty { replaceSynthesizer() }
        resetPlaybackStateForPreview()
        #if os(iOS)
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [.duckOthers])
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
            #if os(iOS)
            if mixesWithOtherAudio, lowersBackgroundAudio { try PlaybackAudioSessionPolicy.releaseDucking() }
            #endif
        }
        #endif
    }

    public func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixesWithOtherAudio = enabled
        #if canImport(AVFoundation) && os(iOS)
        guard !paused, synthesizer.isSpeaking || !chunksByUtteranceId.isEmpty else { return }
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(
            options: PlaybackAudioSessionPolicy.options(mixes: enabled, lowersBackground: lowersBackgroundAudio)
        )
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    public func setLowersBackgroundAudio(_ enabled: Bool) throws {
        lowersBackgroundAudio = enabled
        try setMixesWithOtherAudio(mixesWithOtherAudio)
    }

    public func setPlaybackVolume(_ volume: Float) throws {
        let clamped = max(0, min(1, volume))
        guard playbackVolume != clamped else { return }
        playbackVolume = clamped
        #if canImport(AVFoundation)
        guard synthesizer.isSpeaking,
              !paused,
              let targetId = lastTargetId else { return }
        let restartOffset = currentOffset ?? lastStartOffset
        try play(targetId: targetId, from: restartOffset)
        #endif
    }

    /// The client's own intent for `playback.state` diagnostics (#1109), in the words the on-device voice
    /// client uses: `paused` after a pause that stopped speech, `playing` while speech is queued or
    /// spoken, otherwise `stopped`.
    public var diagnosticIntent: String {
        if paused { return "paused" }
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking || !chunksByUtteranceId.isEmpty { return "playing" }
        #endif
        return "stopped"
    }

    public func currentCharOffset() -> Int? {
        currentOffset
    }

    public func spokenProgress() -> Int? {
        spokenRanges
    }

    public func currentPlaybackPosition() -> PlaybackPosition? {
        guard let currentOffset else { return nil }
        let end = min(preparedSourceText.count, currentOffset + max(1, currentRangeLength))
        return PlaybackPosition(
            targetType: .itemTextTTS,
            targetId: lastTargetId,
            textStart: currentOffset,
            textEnd: end,
            playbackRate: Double(currentSpeechSettings().rate / AVSpeechUtteranceDefaultSpeechRate),
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
        #if os(iOS)
        if mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
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
        // A rate set on this client (the player's speed control) wins over the stored default.
        let rate = hasExplicitSpeechRate || storedRate == 0 ? speechRate : Float(storedRate)
        return (storedVoice?.isEmpty == true ? nil : storedVoice, rate)
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

    /// Narration always speaks as `.appVoice`: never with the Accessibility settings, which
    /// multiplied the listener's speed by the Accessibility speaking rate (#183, I14). With no
    /// voice chosen, it uses the best voice installed for the listener's language.
    private func narrationMode() throws -> SpeechPreviewMode {
        let speechSettings = currentSpeechSettings()
        if let voiceIdentifier = speechSettings.voiceIdentifier,
           !isVoiceAvailable(voiceIdentifier) {
            throw SessionKitError.persistenceFailed("selected_speech_voice_unavailable")
        }
        let voiceIdentifier = speechSettings.voiceIdentifier
            ?? (readsSpeechSettingsAtPlayback ? SystemSpeechVoiceChoice.preferredInstalledVoiceIdentifier() : nil)
        return .appVoice(voiceIdentifier: voiceIdentifier, rate: speechSettings.rate)
    }

    /// The utterance narration would speak `text` with. Tests read its rate and settings.
    func makeNarrationUtterance(_ text: String) throws -> AVSpeechUtterance {
        makeUtterance(text, mode: try narrationMode())
    }

    private func makeUtterance(_ text: String, mode: SpeechPreviewMode) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = playbackVolume
        switch mode {
        case .spokenContent:
            utterance.rate = currentSpeechSettings().rate
            utterance.prefersAssistiveTechnologySettings = true
        case .appVoice(let voiceIdentifier, let rate):
            utterance.rate = SpeechRateRule.systemSpeechRate(
                forMultiplier: SpeechRateRule.multiplier(forStoredRate: rate)
            )
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

/// Picks the system voice narration uses when the listener hasn't chosen one: the best quality
/// installed for their language. Novelty and Personal Voices are never picked.
public enum SystemSpeechVoiceChoice {
    public struct Candidate: Equatable, Sendable {
        public var identifier: String
        public var language: String
        /// 1 default, 2 enhanced, 3 premium.
        public var qualityRank: Int
        public var isLanguageDefault: Bool

        public init(identifier: String, language: String, qualityRank: Int, isLanguageDefault: Bool = false) {
            self.identifier = identifier
            self.language = language
            self.qualityRank = qualityRank
            self.isLanguageDefault = isLanguageDefault
        }
    }

    public static func preferredVoiceIdentifier(among candidates: [Candidate], preferredLanguages: [String]) -> String? {
        for language in preferredLanguages {
            let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
            let base = tag.split(separator: "-").first.map(String.init) ?? tag
            let exact = candidates.filter { $0.language.lowercased() == tag }
            let sameLanguage = candidates.filter {
                ($0.language.lowercased().split(separator: "-").first.map(String.init) ?? "") == base
            }
            for pool in [exact, sameLanguage] where !pool.isEmpty {
                return pool.max { lhs, rhs in
                    (lhs.qualityRank, lhs.isLanguageDefault ? 1 : 0) < (rhs.qualityRank, rhs.isLanguageDefault ? 1 : 0)
                }?.identifier
            }
        }
        return nil
    }

    #if canImport(AVFoundation)
    static func preferredInstalledVoiceIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let defaults = Set(preferredLanguages.compactMap { AVSpeechSynthesisVoice(language: $0)?.identifier })
        let candidates = voices.map { voice in
            Candidate(
                identifier: voice.identifier,
                language: voice.language,
                qualityRank: voice.quality == .premium ? 3 : voice.quality == .enhanced ? 2 : 1,
                isLanguageDefault: defaults.contains(voice.identifier)
            )
        }
        return preferredVoiceIdentifier(among: candidates, preferredLanguages: preferredLanguages)
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
        guard synthesizer === self.synthesizer,
              let chunk = chunksByUtteranceId[ObjectIdentifier(utterance)] else { return }
        activeUtterance = utterance
        currentOffset = chunk.sourceStart
        currentRangeLength = 0
        startedTargetId = lastTargetId
        pendingStartTargetId = nil
        playbackStartFailure = nil
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard synthesizer === self.synthesizer,
              let chunk = chunksByUtteranceId[ObjectIdentifier(utterance)] else { return }
        let spokenLength = chunk.spokenText.utf16.count
        let markerStart = min(characterRange.location, spokenLength)
        let markerLength = min(characterRange.length, spokenLength - markerStart)
        let start = chunk.sourceOffset(atSpokenUTF16Offset: markerStart)
        let end = chunk.sourceOffset(atSpokenUTF16Offset: markerStart + markerLength)
        currentOffset = start
        currentRangeLength = max(0, end - start)
        spokenRanges += 1
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        guard synthesizer === self.synthesizer else { return }
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
            #if os(iOS)
            if mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
            #endif
        }
        pendingStartTargetId = nil
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard synthesizer === self.synthesizer else { return }
        let identifier = ObjectIdentifier(utterance)
        guard chunksByUtteranceId.removeValue(forKey: identifier) != nil else { return }
        if activeUtterance === utterance {
            activeUtterance = nil
        }
        playbackComplete = false
        completedTargetId = nil
        if pendingStartTargetId == lastTargetId {
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
    private var mixesWithOtherAudio = false
    private var lowersBackgroundAudio = false
    private var playbackVolume: Float = 1

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
            nextPlayer.volume = playbackVolume
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
        playbackRate = max(0.25, min(3.0, rate))
        #if canImport(AVFoundation)
        player?.enableRate = true
        if player?.isPlaying == true {
            player?.rate = Float(playbackRate)
        }
        #endif
    }

    public func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixesWithOtherAudio = enabled
        #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
        guard player?.isPlaying == true else { return }
        try configurePreparedAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    public func setLowersBackgroundAudio(_ enabled: Bool) throws {
        lowersBackgroundAudio = enabled
        try setMixesWithOtherAudio(mixesWithOtherAudio)
    }

    public func setPlaybackVolume(_ volume: Float) throws {
        playbackVolume = max(0, min(1, volume))
        #if canImport(AVFoundation)
        player?.volume = playbackVolume
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
        let wasPlaying = player?.isPlaying == true
        player?.pause()
        #if os(iOS)
        if wasPlaying, mixesWithOtherAudio, lowersBackgroundAudio { try PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
        #endif
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        player?.stop()
        player = nil
        activeTargetId = nil
        playbackComplete = false
        completedTargetId = nil
        #if os(iOS)
        if mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
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
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(
            options: PlaybackAudioSessionPolicy.options(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio)
        )
        #endif
    }
    #endif
}

#if canImport(AVFoundation)
extension PreparedAudioPlaybackClient: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        playbackComplete = flag
        completedTargetId = activeTargetId
        #if os(iOS)
        if mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
    }
}
#endif

public enum AudioPlaybackInterruptionEvent: Equatable, Sendable {
    case began
    case endedShouldResume
}

struct AudioPlaybackInterruptionResumePolicy: Equatable {
    private(set) var wasPlayingBeforeInterruption = false

    @discardableResult
    mutating func began(wasPlaying: Bool) -> Bool {
        wasPlayingBeforeInterruption = wasPlaying
        return wasPlaying
    }

    mutating func ended(shouldResume: Bool) -> Bool {
        defer { wasPlayingBeforeInterruption = false }
        return wasPlayingBeforeInterruption && shouldResume
    }

    mutating func cancelAutomaticResume() {
        wasPlayingBeforeInterruption = false
    }
}

struct MediaSeekLifecycle: Equatable {
    enum Observation: Equatable {
        case playbackSample
        case nativeTimeJump
    }

    enum Purpose: Equatable {
        case playbackStart
        case navigation
    }

    struct Pending: Equatable {
        var generation: Int
        var requestId: Int
        var targetId: String
        var mediaTimeMs: Int
        var retryCount: Int
        var purpose: Purpose
        /// Where the player was when the seek began, and when (system uptime), for `abandonIfOverrun`.
        var originMediaTimeMs: Int? = nil
        var beganUptimeMs = 0
        var lastObservedUptimeMs = 0
        var lastObservedPlayerMediaTimeMs: Int? = nil
        var playbackAllowanceMs: Double = 0
        var landingObserved = false
    }

    /// How far past its target the player must be before a pending seek counts as landed.
    static let overrunToleranceMs = 1_000

    enum Resolution: Equatable {
        case ignored
        case completed
        case retry(Pending)
        case failed(Pending)
    }

    private(set) var generation = 0
    private(set) var pending: Pending?

    mutating func begin(
        targetId: String,
        mediaTimeMs: Int,
        purpose: Purpose = .playbackStart,
        originMediaTimeMs: Int? = nil,
        uptimeMs: Int = 0
    ) -> Int {
        generation += 1
        pending = Pending(
            generation: generation,
            requestId: generation,
            targetId: targetId,
            mediaTimeMs: max(0, mediaTimeMs),
            retryCount: 0,
            purpose: purpose,
            originMediaTimeMs: originMediaTimeMs,
            beganUptimeMs: uptimeMs,
            lastObservedUptimeMs: uptimeMs,
            lastObservedPlayerMediaTimeMs: originMediaTimeMs,
            landingObserved: originMediaTimeMs.map {
                abs(Double($0) - Double(max(0, mediaTimeMs))) <= Double(Self.overrunToleranceMs)
            } ?? false
        )
        return generation
    }

    /// A seek whose completion never arrived kept every clock at its target while the audio played
    /// on (#166). Time bounds possible playback; it does not prove landing. Remember a native jump
    /// near the target or a displacement from the origin that ordinary playback cannot explain, then
    /// recover only when the player moves beyond the target. Sample at rate changes as well as ticks
    /// so a slower rate cannot erase playback accumulated at the earlier rate.
    mutating func abandonIfOverrun(playerMediaTimeMs: Int?, uptimeMs: Int, playbackRate: Double,
                                  observation: Observation = .playbackSample) -> Pending? {
        guard var current = pending else { return nil }
        let elapsed = max(0, uptimeMs - current.lastObservedUptimeMs)
        current.playbackAllowanceMs += Double(elapsed) * (playbackRate.isFinite ? max(playbackRate, 0) : 0)
        current.lastObservedUptimeMs = max(current.lastObservedUptimeMs, uptimeMs)
        guard let player = playerMediaTimeMs else {
            pending = current
            return nil
        }
        let moved = current.lastObservedPlayerMediaTimeMs.map { $0 != player } ?? false
        current.lastObservedPlayerMediaTimeMs = player
        let tolerance = Double(Self.overrunToleranceMs)
        let reach = current.playbackAllowanceMs + tolerance
        let pastTarget = Double(player) - Double(current.mediaTimeMs)
        if observation == .nativeTimeJump, abs(pastTarget) <= tolerance {
            current.landingObserved = true
        } else if moved, pastTarget >= -tolerance, pastTarget <= reach,
                  let origin = current.originMediaTimeMs,
                  observation == .nativeTimeJump || player < origin || Double(player) - Double(origin) > reach {
            current.landingObserved = true
        }
        pending = current
        guard moved, current.landingObserved, pastTarget > tolerance, pastTarget <= reach else { return nil }
        invalidate()
        return current
    }

    mutating func finish(generation: Int, targetId: String, completed: Bool) -> Resolution {
        guard let current = pending,
              current.generation == generation,
              current.targetId == targetId else {
            return .ignored
        }
        guard !completed else {
            pending = nil
            return .completed
        }
        guard current.retryCount == 0 else {
            pending = nil
            return .failed(current)
        }
        self.generation += 1
        var retry = current
        retry.generation = self.generation
        retry.retryCount = 1
        pending = retry
        return .retry(retry)
    }

    mutating func invalidate() {
        generation += 1
        pending = nil
    }
}

struct MediaPlaybackCompletionPolicy {
    static let terminalToleranceMs = 1_500

    static func reachedEffectiveEnd(
        completionNotificationObserved: Bool,
        targetMatches: Bool,
        playerIsPaused: Bool,
        userRequestedPause: Bool,
        seekIsPending: Bool,
        currentMediaTimeMs: Int?,
        durationMs: Int?
    ) -> Bool {
        if completionNotificationObserved && targetMatches {
            return true
        }
        guard targetMatches,
              playerIsPaused,
              !userRequestedPause,
              !seekIsPending,
              let currentMediaTimeMs,
              let durationMs,
              durationMs > 0 else {
            return false
        }
        let remainingMs = max(0, durationMs - currentMediaTimeMs)
        return currentMediaTimeMs > 0 && remainingMs <= terminalToleranceMs
    }

    /// Whether a seek to `mediaTimeMs` takes an ended episode back from its end, so its
    /// end-of-item notification no longer holds (#588). Any destination before the end does,
    /// even one inside the terminal tolerance: that tolerance is for a player that stopped on
    /// its own, not for a place the listener chose. Without a known length, any seek does.
    static func seekLeavesEnd(toMediaTimeMs mediaTimeMs: Int, durationMs: Int?) -> Bool {
        guard let durationMs, durationMs > 0 else { return true }
        return mediaTimeMs < durationMs
    }
}

public final class AVPlayerStreamPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    #if canImport(AVFoundation)
    private var player: AVPlayer?
    private var completionObserver: NSObjectProtocol?
    private var timeJumpObserver: NSObjectProtocol?
    private var timeObserverToken: Any?
    private var playerStateObservation: NSKeyValueObservation?
    private var audioSessionObservers: [NSObjectProtocol] = []
    /// Timing of the latest play() until the player reports playing (#160).
    private var pendingStartTrace: (startedAt: TimeInterval, accessLogEvents: Int, fields: [String: String])?
    #endif
    /// Receives one timing record per media start: how long audio session activation, the start seek and the
    /// wait for "playing" took, and whether the stream was fetched again. Field values are numbers or flags.
    public var playbackStartTraceHandler: (@Sendable ([String: String]) -> Void)?
    /// Receives a record when the player's clock stops moving while playback is intended, and when it moves
    /// again (#166). Carries AVPlayer's own state so the log can tell a buffering stall from a frozen clock.
    /// Also receives `event: seek_abandoned` when a seek the player has passed is given up.
    public var playbackStallTraceHandler: (@Sendable ([String: String]) -> Void)?
    private var stallDetector = PlaybackStallDetector()
    private var stallWatchdog: Timer?
    /// Overrules a frozen clock with the decoded audio's own media time (#2094).
    private var clockGuard = DecodedAudioClockGuard()
    /// The decoded audio's position when the listener paused during a clock freeze, kept until the next seek.
    private var pausedTrustedMediaTimeMs: Int?
    private var lastClockRecoveryUptimeMs: Int?
    /// One re-seek per this long at most, so a clock that freezes again can't make the audio stutter.
    static let clockRecoveryIntervalMs = 60_000
    /// Tests only: hold AVPlayer's raw clock at this time, as on the phone in #2094, until the next seek.
    var frozenPlayerClockForTesting: Int?
    private var mediaSeekStartedUptime: TimeInterval?
    /// Tests only: drop AVPlayer's seek completions, as happened on a stream in #166.
    var withholdsSeekCompletionsForTesting = false
    var hasPendingSeekForTesting: Bool { mediaSeekLifecycle.pending != nil }
    var pendingSeekHasLandingEvidenceForTesting: Bool { mediaSeekLifecycle.pending?.landingObserved == true }
    #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
    private var postResumeEvidenceTap: MTAudioProcessingTap?
    private var postResumeEvidenceTapContext: PostResumePodcastEvidenceTapContext?
    private weak var postResumeEvidenceItem: AVPlayerItem?
    private var postResumeEvidenceAudioMix: AVAudioMix?
    private var continuousEvidenceTapTracksObservation: NSKeyValueObservation?
    public var postResumePodcastEvidenceHandler: (@Sendable (PostResumePodcastEvidenceCaptureResult) -> Void)?
    /// Receives the minute before and after each Margin as the listener heard it (#156).
    public var heardSourceWindowHandler: (@Sendable (HeardAudioWindow) -> Void)?
    #endif
    private let remoteCommandHandler: (@Sendable (CompactControlCommand, Int?, Double?) -> Void)?
    /// A headphone double-press arrives as next track. When set, it gets the press instead of skip forward,
    /// so the app can add a Margin by the listener's setting (#2031). Skip forward stays skip forward.
    public var nextTrackHandler: (@Sendable () -> Void)?
    private let interruptionHandler: (@Sendable (AudioPlaybackInterruptionEvent) -> Void)?
    private let audioSessionNotificationCenter: NotificationCenter
    private var mediaContext: PlaybackMediaContext?
    private var activeTargetId: String?
    private var activePlaybackURL: URL?
    /// Where the Xing/VBRI answer for streamed MP3s comes from (#2660); tests inject their own.
    var vbrProbe: MP3VBRHeaderProbe = .shared
    /// How long after an item is built a late "VBR with header" answer may swap in a keyed item (#2660).
    var preciseTimingSwapWindow: TimeInterval = 1.5
    private var activeItemHasPreciseTiming = false
    private var activeItemBuiltAt: TimeInterval = 0
    private var completedTargetId: String?
    private var playbackComplete = false
    private var lastRequestedMediaTimeMs = 0
    private var mediaSeekLifecycle = MediaSeekLifecycle()
    private var mediaSeekFailure: String?
    private var navigationSeekResolutions: [Int: MediaSeekResolution] = [:]
    private var navigationSeekResolutionOrder: [Int] = []
    private var knownDurations: [String: Int] = [:]
    private var playbackRate: Double = 1
    private var mixesWithOtherAudio = false
    private var lowersBackgroundAudio = false
    private var playbackVolume: Float = 1
    /// Every way playback pauses (the listener, a phone call or announcement, a lost route, the end of the item)
    /// passes through here, so each keeps where the audio was during a clock freeze, not the frozen time (#2094).
    private var paused = true {
        willSet {
            guard newValue, !paused else { return }
            pausedTrustedMediaTimeMs = decodedAudioMediaTimeMs(overruling: reportedMediaTimeMs())
            clockGuard.notePaused()
        }
    }
    private var remoteCommandHandlingEnabled = true
    private var interruptionResumePolicy = AudioPlaybackInterruptionResumePolicy()
    /// Background time while an interruption waits to end, so a backgrounded app isn't suspended before iOS says
    /// it is over (#1434).
    private let interruptionHold: InterruptionBackgroundHold?
    private var preferredSkipBackSeconds: Int
    private var preferredSkipForwardSeconds: Int

    #if canImport(MediaPlayer) && os(iOS)
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    #endif

    public init(
        preferredSkipBackSeconds: Int = 15,
        preferredSkipForwardSeconds: Int = 15,
        audioSessionNotificationCenter: NotificationCenter = .default,
        interruptionHandler: (@Sendable (AudioPlaybackInterruptionEvent) -> Void)? = nil,
        interruptionHold: InterruptionBackgroundHold? = nil,
        remoteCommandHandler: (@Sendable (CompactControlCommand, Int?, Double?) -> Void)? = nil
    ) {
        self.preferredSkipBackSeconds = Self.validatedSkipSeconds(preferredSkipBackSeconds)
        self.preferredSkipForwardSeconds = Self.validatedSkipSeconds(preferredSkipForwardSeconds)
        self.audioSessionNotificationCenter = audioSessionNotificationCenter
        self.interruptionHandler = interruptionHandler
        self.interruptionHold = interruptionHold
        self.remoteCommandHandler = remoteCommandHandler
        installAudioSessionObservers()
        installRemoteCommandHandlers()
    }

    public func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        remoteCommandHandlingEnabled = enabled
        if enabled {
            installRemoteCommandHandlers()
            publishNowPlaying(isPlaying: !paused)
        } else {
            removeRemoteCommandHandlers()
            clearNowPlaying()
        }
    }

    public func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixesWithOtherAudio = enabled
        #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
        guard player != nil, !paused, !playbackComplete else { return }
        try configureStreamAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    public func setLowersBackgroundAudio(_ enabled: Bool) throws {
        lowersBackgroundAudio = enabled
        try setMixesWithOtherAudio(mixesWithOtherAudio)
    }

    public func setPlaybackVolume(_ volume: Float) throws {
        playbackVolume = max(0, min(1, volume))
        #if canImport(AVFoundation)
        player?.volume = min(1, playbackVolume)
        #endif
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
        cancelPostResumeEvidenceCapture(reason: "playback_client_deinitialized")
        removePlayerStateObserver()
        removeCompletionObserver()
        removeTimeObserver()
        removeRemoteCommandHandlers()
        withInterruptionHold { $0.listenerActed() }
        for observer in audioSessionObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
    }

    public func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        if context?.targetId != mediaContext?.targetId {
            cancelAutomaticInterruptionResume()
        }
        mediaContext = context
        // Learn whether a streamed MP3 has a Xing/VBRI header before play() builds its item (#2660).
        if let context, let url = URL(string: context.playbackURL ?? context.targetId) {
            if let task = vbrProbe.prefetch(url) {
                Task.detached { [weak self] in
                    await task.value
                    DispatchQueue.main.async { self?.probeAnswered(for: url) }
                }
            }
        }
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

    /// Replaces the player and its observers with a fresh item for `url`.
    private func installPlayerItem(url: URL, targetId: String) {
        let setupLabel = MainThreadOperationLabels.shared.push("avPlayer.itemSetup") // names a slow setup in a hang (#2255)
        defer { MainThreadOperationLabels.shared.pop(setupLabel) }
        cancelPostResumeEvidenceCapture(reason: "playback_item_changed")
        removePlayerStateObserver()
        removeCompletionObserver()
        removeTimeObserver()
        let keyed = Self.wantsPreciseTiming(for: url, probe: vbrProbe)
        let item = AVPlayerItem(asset: Self.playbackAsset(for: url, probe: vbrProbe))
        activeItemHasPreciseTiming = keyed
        activeItemBuiltAt = ProcessInfo.processInfo.systemUptime
        player = AVPlayer(playerItem: item)
        player?.volume = playbackVolume
        player?.automaticallyWaitsToMinimizeStalling = true
        activeTargetId = targetId
        activePlaybackURL = url
        observeCompletion(for: item)
        installPlayerStateObserver()
        installTimeObserver()
        installContinuousPodcastEvidenceTapWhenTracksLoad(on: item)
    }

    /// The probe said a streamed MP3 is VBR with a header (#2660), after its item was built without the key.
    /// Inside the swap window (before meaningful audio) the playing item is rebuilt keyed at the same place;
    /// later, `requestMediaSeek` rebuilds it before the next deliberate seek. Never moves audible audio.
    func probeAnswered(for url: URL) {
        guard vbrProbe.cachedAnswer(for: url) == true, !activeItemHasPreciseTiming,
              activePlaybackURL == url, let targetId = activeTargetId, player != nil, !paused,
              // play() supersedes any pending seek (the listener's, or the start seek still buffering), and the
              // new player's clock would be what the engine is told. Leave those to the next deliberate seek.
              mediaSeekLifecycle.pending == nil,
              ProcessInfo.processInfo.systemUptime - activeItemBuiltAt < preciseTimingSwapWindow else { return }
        let heardMs = currentMediaTimeMs() ?? lastRequestedMediaTimeMs
        activePlaybackURL = nil
        try? play(targetId: targetId, fromMediaTimeMs: max(lastRequestedMediaTimeMs, heardMs))
    }

    /// Before a deliberate seek on an unkeyed item whose URL is now known to be VBR with a header.
    private func upgradeItemBeforeSeek() {
        // Not while an earlier seek is pending: rebuilding the player first would make that seek's "superseded"
        // answer read the new player's clock. The seek that follows still lands; the next settled one upgrades.
        guard !activeItemHasPreciseTiming, let url = activePlaybackURL, let targetId = activeTargetId,
              mediaSeekLifecycle.pending == nil,
              vbrProbe.cachedAnswer(for: url) == true else { return }
        installPlayerItem(url: url, targetId: targetId)
        if !paused {
            player?.play()
            player?.rate = Float(playbackRate)
        }
    }

    public func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        #if canImport(AVFoundation)
        cancelAutomaticInterruptionResume()
        let requestedURL = mediaContext?.targetId == targetId ? mediaContext?.playbackURL : nil
        guard let url = URL(string: requestedURL ?? targetId) else {
            throw SessionKitError.invalidCommandForState("stream_audio_invalid_url:\(requestedURL ?? targetId)")
        }
        // Resuming immediately after navigation (for example after a Skim
        // bridge) must not supersede the very seek the engine is awaiting.
        // Only reuse it for the same player, target and exact destination.
        let continuesNavigationSeek = activeTargetId == targetId
            && activePlaybackURL == url && player != nil
            && mediaSeekLifecycle.pending?.purpose == .navigation
            && mediaSeekLifecycle.pending?.targetId == targetId
            && mediaSeekLifecycle.pending?.mediaTimeMs == max(0, mediaTimeMs)
        let traceStartedAt = ProcessInfo.processInfo.systemUptime
        let rebuildsItem = activeTargetId != targetId || activePlaybackURL != url || player == nil
        if activeTargetId != targetId || activePlaybackURL != url || player == nil {
            installPlayerItem(url: url, targetId: targetId)
        }
        let sessionStartedAt = ProcessInfo.processInfo.systemUptime
        #if os(iOS) || os(watchOS)
        try configureStreamAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let sessionMs = Int((ProcessInfo.processInfo.systemUptime - sessionStartedAt) * 1000)
        let playerTimeMs = player.map { Int(($0.currentTime().seconds.isFinite ? $0.currentTime().seconds : -1) * 1000) } ?? -1
        pendingStartTrace = (
            startedAt: traceStartedAt,
            accessLogEvents: player?.currentItem?.accessLog()?.events.count ?? 0,
            fields: [
                "newItem": rebuildsItem ? "1" : "0",
                "stream": url.isFileURL ? "0" : "1",
                "sessionMs": String(sessionMs),
                "seek": continuesNavigationSeek ? "reused" : "issued",
                "seekDistanceMs": String(playerTimeMs < 0 ? -1 : abs(playerTimeMs - max(0, mediaTimeMs))),
                "tap": hasPodcastEvidenceTap ? "1" : "0"
            ]
        )
        let seconds = max(0, Double(mediaTimeMs) / 1000)
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        playbackComplete = false
        completedTargetId = nil
        paused = false
        pausedTrustedMediaTimeMs = nil
        if !continuesNavigationSeek {
            let seekGeneration = beginMediaSeek(
                targetId: targetId,
                mediaTimeMs: lastRequestedMediaTimeMs,
                purpose: .playbackStart
            )
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            let seekStartedAt = ProcessInfo.processInfo.systemUptime
            player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                DispatchQueue.main.async { [weak self] in
                    if self?.pendingStartTrace?.startedAt == traceStartedAt {
                        self?.pendingStartTrace?.fields["seekMs"] = String(Int((ProcessInfo.processInfo.systemUptime - seekStartedAt) * 1000))
                    }
                    self?.finishMediaSeek(generation: seekGeneration, targetId: targetId, finished: finished)
                }
            }
        }
        player?.play()
        player?.rate = Float(playbackRate)
        publishNowPlaying(isPlaying: true)
        startStallWatchdog()
        #else
        throw SessionKitError.persistenceFailed("stream_audio_playback_unavailable")
        #endif
    }

    public func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        _ = try requestMediaSeek(toMediaTimeMs: mediaTimeMs)
    }

    #if canImport(AVFoundation)
    /// A downloaded episode asks for precise timing (#2094). Without it, a seek in a VBR MP3 played audio up to
    /// about five minutes from where the clock said, on macOS with real decoding, while the clock read the
    /// requested time; with it every seek landed within 13 ms. The cost on a local file is a frame scan only when
    /// the MP3 has no Xing header (about 1.2 s for an hour). Streams keep the default (#2110, `ops/stream-seek`): over
    /// HTTP the key makes AVFoundation fetch the whole file before playing when the MP3 has no header (14 s for a
    /// 29 MB CBR file at 20 Mbit/s), or 13 to 24 MB on the first seeks when it has one. Only a VBR file with a Xing
    /// header is both cheap with the key (0.3 s to start) and wrong without it (seeks up to 9 s off).
    /// A stream whose first frame was probed as Xing or VBRI gets the key too (#2660). An unprobed, failed or
    /// other stream does not. The probe runs in `configureMediaContext`, never here.
    static func playbackAsset(for url: URL, probe: MP3VBRHeaderProbe = .shared) -> AVURLAsset {
        AVURLAsset(url: url, options: wantsPreciseTiming(for: url, probe: probe) ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil)
    }

    static func wantsPreciseTiming(for url: URL, probe: MP3VBRHeaderProbe = .shared) -> Bool {
        url.isFileURL || probe.cachedAnswer(for: url) == true
    }

    /// Whether the playing item's asset was created with the precise-timing key (for a stream, the loaded
    /// property below stays false until the asset has loaded).
    var currentItemWasBuiltKeyedForTesting: Bool { activeItemHasPreciseTiming }

    var currentItemProvidesPreciseTimingForTesting: Bool? {
        (player?.currentItem?.asset as? AVURLAsset)?.providesPreciseDurationAndTiming
    }
    #endif

    public func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        #if canImport(AVFoundation)
        if let context = postResumeEvidenceTapContext, context.retainsContinuousCollection {
            context.noteSeek()
        } else {
            cancelPostResumeEvidenceCapture(reason: "playback_seeked_during_capture")
        }
        upgradeItemBeforeSeek()
        let seconds = max(0, Double(mediaTimeMs) / 1000)
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        guard let player, let activeTargetId else {
            throw SessionKitError.invalidCommandForState("media_seek_player_unavailable")
        }
        // Scrubbing back from the end leaves the episode paused at the new place, not ended:
        // a kept completion flag would move it straight back to the end (#588).
        if playbackComplete,
           MediaPlaybackCompletionPolicy.seekLeavesEnd(
               toMediaTimeMs: lastRequestedMediaTimeMs, durationMs: durationMs(for: activeTargetId)
           ) {
            playbackComplete = false
            completedTargetId = nil
        }
        let seekGeneration = beginMediaSeek(
            targetId: activeTargetId,
            mediaTimeMs: lastRequestedMediaTimeMs,
            purpose: .navigation
        )
        let request = MediaSeekRequest(
            id: mediaSeekLifecycle.pending?.requestId ?? seekGeneration,
            targetId: activeTargetId,
            requestedMediaTimeMs: lastRequestedMediaTimeMs
        )
        storeNavigationSeekResolution(.pending, for: request.id)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                self?.finishMediaSeek(generation: seekGeneration, targetId: activeTargetId, finished: finished)
            }
        }
        publishNowPlaying(isPlaying: !paused)
        return request
        #else
        lastRequestedMediaTimeMs = max(0, mediaTimeMs)
        return MediaSeekRequest(id: 0, targetId: activeTargetId, requestedMediaTimeMs: lastRequestedMediaTimeMs)
        #endif
    }

    public func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution {
        if let pending = mediaSeekLifecycle.pending,
           pending.requestId == request.id,
           pending.targetId == request.targetId {
            return .pending
        }
        return navigationSeekResolutions[request.id]
            ?? .failed(actualMediaTimeMs: currentMediaTimeMs(), reason: "media_seek_superseded")
    }

    public func setPlaybackRate(_ rate: Double) throws {
        // Account for the interval at the old rate before changing it (#166).
        abandonOverrunMediaSeek(uptime: ProcessInfo.processInfo.systemUptime)
        playbackRate = max(0.25, min(3.0, rate))
        #if canImport(AVFoundation)
        if !paused {
            player?.rate = Float(playbackRate)
        }
        publishNowPlaying(isPlaying: !paused)
        #endif
    }

    public func currentPlayerRate() -> Double? {
        #if canImport(AVFoundation)
        guard let player else { return nil }
        // A playing player reports its own rate; stalled or paused (rate 0) it will resume at the one asked for.
        return player.rate > 0 ? Double(player.rate) : playbackRate
        #else
        return nil
        #endif
    }

    @discardableResult
    public func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            guard mediaContext?.itemId == request.itemId,
                  let item = player?.currentItem else { return false }
            if let context = postResumeEvidenceTapContext,
               postResumeEvidenceItem === item {
                return context.arm(request)
            }

            cancelPostResumeEvidenceCapture(reason: "playback_capture_replaced")
            guard let assetTrack = item.tracks
                .compactMap({ $0.assetTrack })
                .first(where: { $0.mediaType == .audio }) else {
                return false
            }
            let context = PostResumePodcastEvidenceTapContext(
                resultHandler: { [weak self] result in
                    self?.postResumePodcastEvidenceHandler?(result)
                },
                becameIdle: { [weak self, weak item] in
                    DispatchQueue.main.async {
                        guard let self, self.postResumeEvidenceItem === item else { return }
                        self.removePostResumeEvidenceTap()
                    }
                }
            )
            guard context.arm(request) else { return false }
            do {
                let tap = try PostResumePodcastEvidenceTapFactory.make(context: context)
                let parameters = AVMutableAudioMixInputParameters(track: assetTrack)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                postResumeEvidenceTap = tap
                postResumeEvidenceTapContext = context
                postResumeEvidenceItem = item
                postResumeEvidenceAudioMix = mix
                item.audioMix = mix
                return true
            } catch {
                context.cancelAll(reason: "decoded_playback_tap_install_failed:\(error.localizedDescription)")
                removePostResumeEvidenceTap()
                return false
            }
        }
        #else
        _ = request
        return false
        #endif
    }

    @discardableResult
    public func captureBufferedPreInterjectionAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            guard mediaContext?.itemId == request.itemId,
                  let context = postResumeEvidenceTapContext,
                  postResumeEvidenceItem === player?.currentItem else { return false }
            return context.captureBufferedPreInterjection(request)
        }
        #else
        _ = request
        return false
        #endif
    }

    public func isUsingPlaybackURL(_ url: URL, itemId: String) -> Bool {
        mediaContext?.itemId == itemId && activePlaybackURL?.standardizedFileURL == url.standardizedFileURL
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
        let reported = reportedMediaTimeMs()
        if paused { return pausedTrustedMediaTimeMs ?? reported }
        return decodedAudioMediaTimeMs(overruling: reported) ?? reported
    }

    /// The pending seek's target, else the player's own clock: what AVPlayer claims, before any evidence check.
    private func reportedMediaTimeMs() -> Int {
        if let pendingMediaSeek = mediaSeekLifecycle.pending,
           pendingMediaSeek.targetId == activeTargetId {
            return pendingMediaSeek.mediaTimeMs
        }
        #if canImport(AVFoundation)
        guard player != nil else { return lastRequestedMediaTimeMs }
        return observedPlayerMediaTimeMs() ?? lastRequestedMediaTimeMs
        #else
        return lastRequestedMediaTimeMs
        #endif
    }

    /// The media time the decoded audio shows the listener at, when the reported time has frozen behind it
    /// while playing (#2094). Anything that reads the position (a new Margin's anchor, its rejoin, the saved
    /// resume position, Now Playing) then follows the audio rather than a stale clock.
    private func decodedAudioMediaTimeMs(overruling reported: Int) -> Int? {
        guard player != nil, !paused else { return nil }
        return clockGuard.observe(
            reportedMediaTimeMs: reported,
            rawClockMediaTimeMs: observedPlayerMediaTimeMs(),
            decoded: latestDecodedAudioSample(),
            uptimeMs: DecodedAudioClockGuard.uptimeMs()
        )
    }

    private func latestDecodedAudioSample() -> DecodedAudioClockGuard.DecodedSample? {
        #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        guard let context = postResumeEvidenceTapContext,
              postResumeEvidenceItem != nil, postResumeEvidenceItem === player?.currentItem else { return nil }
        return context.latestDecodedSample
        #else
        return nil
        #endif
    }

    public func currentPlaybackDurationMs() -> Int? {
        guard let activeTargetId else { return nil }
        return durationMs(for: activeTargetId)
    }

    public func isPlaybackComplete(targetId: String) -> Bool {
        let complete = effectivePlaybackComplete(targetId: targetId)
        if complete { releaseBackgroundAudio() }
        return complete
    }

    private func releaseBackgroundAudio() {
        #if os(iOS)
        if player != nil, mixesWithOtherAudio, lowersBackgroundAudio {
            try? PlaybackAudioSessionPolicy.releaseDucking()
        }
        #endif
    }

    public func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        guard activeTargetId == targetId else { return .pending }
        if let mediaSeekFailure {
            releaseBackgroundAudio()
            return .failed(mediaSeekFailure)
        }
        if mediaSeekLifecycle.pending?.targetId == targetId {
            return .pending
        }
        #if canImport(AVFoundation)
        if let error = player?.currentItem?.error {
            releaseBackgroundAudio()
            return .failed(PlaybackFailureDetail.describe(error))
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
        if mediaSeekFailure != nil {
            releaseBackgroundAudio()
            return .failed
        }
        if mediaSeekLifecycle.pending?.targetId == targetId {
            return .waiting
        }
        #if canImport(AVFoundation)
        if player?.currentItem?.error != nil {
            releaseBackgroundAudio()
            return .failed
        }
        switch player?.timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        case .paused:
            // AVPlayer reports transient `.paused` states while replacing,
            // seeking, and recovering a stream. Only surface a canonical pause
            // when the user actually requested one.
            return effectivePlaybackComplete(targetId: targetId) ? .stopped : (paused ? .paused : .waiting)
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
        cancelAutomaticInterruptionResume()
        paused = true
        player?.pause()
        stopStallWatchdog()
        #if os(iOS)
        if player != nil, mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
        publishNowPlaying(isPlaying: false)
        #endif
    }

    public func stop() throws {
        #if canImport(AVFoundation)
        cancelPostResumeEvidenceCapture(reason: "playback_stopped_during_capture")
        cancelAutomaticInterruptionResume()
        invalidatePendingMediaSeek()
        player?.pause()
        stopStallWatchdog()
        removePlayerStateObserver()
        removeCompletionObserver()
        removeTimeObserver()
        player = nil
        activeTargetId = nil
        activePlaybackURL = nil
        completedTargetId = nil
        playbackComplete = false
        mediaSeekFailure = nil
        paused = true
        pausedTrustedMediaTimeMs = nil
        clockGuard = DecodedAudioClockGuard()
        clearNowPlaying()
        #if os(iOS)
        if mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
    }

    private func beginMediaSeek(
        targetId: String,
        mediaTimeMs: Int,
        purpose: MediaSeekLifecycle.Purpose
    ) -> Int {
        if let pending = mediaSeekLifecycle.pending, pending.purpose == .navigation {
            storeNavigationSeekResolution(
                .failed(actualMediaTimeMs: observedPlayerMediaTimeMs(), reason: "media_seek_superseded"),
                for: pending.requestId
            )
        }
        mediaSeekFailure = nil
        frozenPlayerClockForTesting = nil
        pausedTrustedMediaTimeMs = nil
        clockGuard.noteSeek(uptimeMs: DecodedAudioClockGuard.uptimeMs())
        let uptime = ProcessInfo.processInfo.systemUptime
        mediaSeekStartedUptime = uptime
        return mediaSeekLifecycle.begin(
            targetId: targetId, mediaTimeMs: mediaTimeMs, purpose: purpose,
            originMediaTimeMs: observedPlayerMediaTimeMs(), uptimeMs: Int(uptime * 1_000)
        )
    }

    /// Native jumps supply landing evidence; watchdog/rate samples only supply movement and bounds.
    private func abandonOverrunMediaSeek(uptime: TimeInterval,
                                        observation: MediaSeekLifecycle.Observation = .playbackSample) {
        let observed = observedPlayerMediaTimeMs()
        guard let abandoned = mediaSeekLifecycle.abandonIfOverrun(
            playerMediaTimeMs: observed, uptimeMs: Int(uptime * 1_000), playbackRate: playbackRate,
            observation: observation
        ) else { return }
        mediaSeekFailure = nil
        if abandoned.purpose == .navigation {
            storeNavigationSeekResolution(.accepted(mediaTimeMs: observed ?? abandoned.mediaTimeMs), for: abandoned.requestId)
        }
        var fields = [
            "event": "seek_abandoned", "toMs": String(abandoned.mediaTimeMs),
            "purpose": abandoned.purpose == .navigation ? "navigation" : "start",
            "retry": String(abandoned.retryCount),
            "ageMs": String(Int(uptime * 1_000) - abandoned.beganUptimeMs)
        ]
        fields.merge(playerStateFields(uptime: uptime)) { current, _ in current }
        playbackStallTraceHandler?(fields)
        publishNowPlaying(isPlaying: !paused)
    }

    private func startStallWatchdog() {
        guard stallWatchdog == nil else { return }
        stallDetector.reset()
        // A plain timer, not a periodic time observer: those run on the player's clock, which is what freezes.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkForStall() }
        RunLoop.main.add(timer, forMode: .common)
        stallWatchdog = timer
    }

    private func stopStallWatchdog() {
        checkForStall()
        stallWatchdog?.invalidate()
        stallWatchdog = nil
        stallDetector.reset()
    }

    private func checkForStall() {
        let uptime = ProcessInfo.processInfo.systemUptime
        abandonOverrunMediaSeek(uptime: uptime)
        // Also keeps the guard's view of the clock current when nothing else reads the position.
        let decodedMediaTimeMs = decodedAudioMediaTimeMs(overruling: reportedMediaTimeMs())
        guard let event = stallDetector.observe(
            uptimeMs: Int(uptime * 1_000),
            mediaTimeMs: observedPlayerMediaTimeMs(),
            intendsToPlay: !paused && player != nil
        ) else { return }
        var fields: [String: String]
        switch event {
        case .stalled(let atMediaTimeMs, let forMs):
            fields = ["event": "stalled", "atMs": String(atMediaTimeMs), "forMs": String(forMs)]
            if let decodedMediaTimeMs {
                fields["decodedMs"] = String(decodedMediaTimeMs)
                fields["decodeLeadMs"] = String(clockGuard.decodeLeadMs)
            }
        case .ended(let fromMediaTimeMs, let toMediaTimeMs, let stalledForMs):
            fields = [
                "event": "ended", "fromMs": String(fromMediaTimeMs),
                "toMs": toMediaTimeMs.map(String.init) ?? "none", "stalledForMs": String(stalledForMs)
            ]
        }
        fields.merge(playerStateFields(uptime: uptime)) { current, _ in current }
        playbackStallTraceHandler?(fields)
        if case .stalled(let atMediaTimeMs, _) = event, let decodedMediaTimeMs {
            recoverFrozenClock(at: decodedMediaTimeMs, frozenAtMs: atMediaTimeMs, uptime: uptime)
        }
    }

    /// The audio played on while AVPlayer's clock stood still (#2094). Seek to where the audio is, so the
    /// player's own timeline, the scrubber and Now Playing follow it again; the position is already reported
    /// from the decoded audio until then.
    private func recoverFrozenClock(at mediaTimeMs: Int, frozenAtMs: Int, uptime: TimeInterval) {
        #if canImport(AVFoundation)
        let uptimeMs = DecodedAudioClockGuard.uptimeMs()
        if let last = lastClockRecoveryUptimeMs, uptimeMs - last < Self.clockRecoveryIntervalMs { return }
        guard let player, let activeTargetId else { return }
        lastClockRecoveryUptimeMs = uptimeMs
        let superseded = mediaSeekLifecycle.pending
        let generation = beginMediaSeek(targetId: activeTargetId, mediaTimeMs: mediaTimeMs, purpose: .playbackStart)
        if let superseded, superseded.purpose == .navigation {
            // The audio is past that seek's target, so it landed; its completion just never said so.
            storeNavigationSeekResolution(.accepted(mediaTimeMs: mediaTimeMs), for: superseded.requestId)
        }
        lastRequestedMediaTimeMs = mediaTimeMs
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: Double(mediaTimeMs) / 1_000, preferredTimescale: 600),
            toleranceBefore: tolerance, toleranceAfter: tolerance
        ) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                self?.finishMediaSeek(generation: generation, targetId: activeTargetId, finished: finished)
            }
        }
        var fields = ["event": "clock_recovered", "fromMs": String(frozenAtMs), "toMs": String(mediaTimeMs),
                      "decodeLeadMs": String(clockGuard.decodeLeadMs)]
        fields.merge(playerStateFields(uptime: uptime)) { current, _ in current }
        playbackStallTraceHandler?(fields)
        #endif
    }

    /// AVPlayer's own state right now, in the fields the stall trace carries, plus `uptimeMs` (#835). Unlike
    /// `currentMediaTimeMs()`, `playerMs` is the player's raw clock even while a seek is pending, so a caller can
    /// tell a frozen player clock from a pending seek or a buffering wait.
    public func playbackStateTraceFields() -> [String: String] {
        let uptime = ProcessInfo.processInfo.systemUptime
        var fields = playerStateFields(uptime: uptime)
        fields["uptimeMs"] = String(Int(uptime * 1_000))
        return fields
    }

    private func playerStateFields(uptime: TimeInterval) -> [String: String] {
        var fields: [String: String] = ["intendsToPlay": paused ? "0" : "1", "tap": hasPodcastEvidenceTap ? "1" : "0"]
        if let pending = mediaSeekLifecycle.pending {
            fields["pendingSeek"] = "\(pending.purpose == .navigation ? "navigation" : "start"):retry\(pending.retryCount)"
            fields["pendingSeekToMs"] = String(pending.mediaTimeMs)
            fields["pendingSeekAgeMs"] = mediaSeekStartedUptime.map { String(Int((uptime - $0) * 1_000)) } ?? "unknown"
        } else {
            fields["pendingSeek"] = "none"
        }
        guard let player else { return fields }
        fields["playerMs"] = observedPlayerMediaTimeMs().map(String.init) ?? "none"
        fields["rate"] = String(format: "%.2f", player.rate)
        switch player.timeControlStatus {
        case .playing: fields["timeControl"] = "playing"
        case .paused: fields["timeControl"] = "paused"
        case .waitingToPlayAtSpecifiedRate: fields["timeControl"] = "waiting"
        @unknown default: fields["timeControl"] = "unknown"
        }
        fields["waitingReason"] = player.reasonForWaitingToPlay.map { $0.rawValue } ?? "none"
        if let item = player.currentItem {
            fields["itemStatus"] = item.status == .readyToPlay ? "ready" : (item.status == .failed ? "failed" : "unknown")
            fields["keepUp"] = item.isPlaybackLikelyToKeepUp ? "1" : "0"
            fields["bufferEmpty"] = item.isPlaybackBufferEmpty ? "1" : "0"
            let now = item.currentTime()
            if let range = item.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.containsTime(now) }) {
                fields["bufferedAheadMs"] = String(Int((CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - now.seconds) * 1_000))
            } else {
                fields["bufferedAheadMs"] = "0"
            }
            fields["stream"] = (item.asset as? AVURLAsset)?.url.isFileURL == false ? "1" : "0"
        }
        return fields
    }

    private func finishMediaSeek(generation: Int, targetId: String, finished: Bool) {
        guard !withholdsSeekCompletionsForTesting else { return }
        // AVPlayer calls the completion handler once for both completed and
        // interrupted seeks. A false result is terminal for this generation;
        // retaining it as pending forever freezes every derived progress
        // surface at the requested time even if audible playback continues.
        let completing = mediaSeekLifecycle.pending
        let resolution = mediaSeekLifecycle.finish(
            generation: generation,
            targetId: targetId,
            completed: finished
        )
        switch resolution {
        case .ignored:
            return
        case .completed:
            mediaSeekFailure = nil
            if let completing, completing.purpose == .navigation {
                storeNavigationSeekResolution(
                    .accepted(mediaTimeMs: observedPlayerMediaTimeMs() ?? completing.mediaTimeMs),
                    for: completing.requestId
                )
            }
        case .retry(let retry):
            guard let player else {
                mediaSeekLifecycle.invalidate()
                if retry.purpose == .navigation {
                    storeNavigationSeekResolution(
                        .failed(actualMediaTimeMs: observedPlayerMediaTimeMs(), reason: "media_seek_player_unavailable"),
                        for: retry.requestId
                    )
                } else {
                    mediaSeekFailure = "media_seek_player_unavailable"
                }
                publishNowPlaying(isPlaying: !paused)
                return
            }
            let time = CMTime(
                seconds: Double(retry.mediaTimeMs) / 1_000,
                preferredTimescale: 600
            )
            let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                DispatchQueue.main.async { [weak self] in
                    self?.finishMediaSeek(
                        generation: retry.generation,
                        targetId: retry.targetId,
                        finished: finished
                    )
                }
            }
            return
        case .failed(let failed):
            if let observed = observedPlayerMediaTimeMs() {
                lastRequestedMediaTimeMs = observed
            }
            if failed.purpose == .navigation {
                storeNavigationSeekResolution(
                    .failed(actualMediaTimeMs: observedPlayerMediaTimeMs(), reason: "media_seek_not_completed"),
                    for: failed.requestId
                )
            } else {
                mediaSeekFailure = "media_seek_not_completed"
            }
        }
        publishNowPlaying(isPlaying: !paused)
    }

    private func observedPlayerMediaTimeMs() -> Int? {
        #if canImport(AVFoundation)
        if let frozenPlayerClockForTesting, player != nil { return frozenPlayerClockForTesting }
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return nil }
        return max(0, Int((seconds * 1_000).rounded()))
        #else
        return lastRequestedMediaTimeMs
        #endif
    }

    private func storeNavigationSeekResolution(_ resolution: MediaSeekResolution, for requestId: Int) {
        navigationSeekResolutions[requestId] = resolution
        if !navigationSeekResolutionOrder.contains(requestId) {
            navigationSeekResolutionOrder.append(requestId)
        }
        while navigationSeekResolutionOrder.count > 8 {
            let expired = navigationSeekResolutionOrder.removeFirst()
            navigationSeekResolutions.removeValue(forKey: expired)
        }
    }

    private func invalidatePendingMediaSeek() {
        if let pending = mediaSeekLifecycle.pending, pending.purpose == .navigation {
            storeNavigationSeekResolution(
                .failed(actualMediaTimeMs: observedPlayerMediaTimeMs(), reason: "media_seek_cancelled"),
                for: pending.requestId
            )
        }
        mediaSeekLifecycle.invalidate()
        mediaSeekFailure = nil
    }

    private func cancelPostResumeEvidenceCapture(reason: String) {
        #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        postResumeEvidenceTapContext?.cancelAll(reason: reason)
        removePostResumeEvidenceTap()
        #else
        _ = reason
        #endif
    }

    /// A new `AVPlayerItem` has no tracks yet, so the tap can't be installed when the item is created. Watch
    /// `tracks` and install once the audio track appears; before this, the continuous tap never installed and
    /// every pre-window capture failed (#154).
    private func installContinuousPodcastEvidenceTapWhenTracksLoad(on item: AVPlayerItem) {
        #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        continuousEvidenceTapTracksObservation?.invalidate()
        continuousEvidenceTapTracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self, weak item] _, _ in
            let install = {
                guard let self, let item, self.player?.currentItem === item else { return }
                MainActor.assumeIsolated {
                    // Unlabeled main-thread work hid what froze a mapped episode's start (#2255).
                    if MainThreadOperationLabels.shared.scoped("avPlayer.evidenceTap", { self.installContinuousPodcastEvidenceTapIfPossible(on: item) }) {
                        self.continuousEvidenceTapTracksObservation?.invalidate()
                        self.continuousEvidenceTapTracksObservation = nil
                    }
                }
            }
            if Thread.isMainThread { install() } else { DispatchQueue.main.async(execute: install) }
        }
        #else
        _ = item
        #endif
    }

    #if canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
    /// True once a tap is attached to the current item; exposed for host tests.
    var hasPodcastEvidenceTapOnCurrentItem: Bool {
        postResumeEvidenceTapContext != nil && postResumeEvidenceItem != nil && postResumeEvidenceItem === player?.currentItem
    }

    /// Returns true when there's nothing left to wait for: a tap is attached, or this item never gets one.
    @MainActor
    @discardableResult
    private func installContinuousPodcastEvidenceTapIfPossible(on item: AVPlayerItem) -> Bool {
        guard let mediaContext,
              mediaContext.targetType == .transcriptBackedMedia,
              mediaContext.sourceType == .remoteStream || mediaContext.sourceType == .nativeMediaFile else {
            return true
        }
        guard postResumeEvidenceTapContext == nil else { return true }
        guard
              mediaContext.targetType == .transcriptBackedMedia,
              mediaContext.sourceType == .remoteStream || mediaContext.sourceType == .nativeMediaFile,
              let assetTrack = item.tracks.compactMap({ $0.assetTrack }).first(where: { $0.mediaType == .audio }) else {
            return false
        }
        let context = PostResumePodcastEvidenceTapContext(
            resultHandler: { [weak self] result in
                self?.postResumePodcastEvidenceHandler?(result)
            },
            becameIdle: {},
            continuousCollection: true,
            itemId: mediaContext.itemId,
            heardWindowHandler: { [weak self] window in self?.heardSourceWindowHandler?(window) }
        )
        do {
            let tap = try PostResumePodcastEvidenceTapFactory.make(context: context)
            let parameters = AVMutableAudioMixInputParameters(track: assetTrack)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            postResumeEvidenceTap = tap
            postResumeEvidenceTapContext = context
            postResumeEvidenceItem = item
            postResumeEvidenceAudioMix = mix
            item.audioMix = mix
        } catch {
            context.cancelAll(reason: "continuous_decoded_playback_tap_install_failed:\(error.localizedDescription)")
            removePostResumeEvidenceTap()
        }
        return true
    }

    private func removePostResumeEvidenceTap() {
        let item = postResumeEvidenceItem
        let mix = postResumeEvidenceAudioMix
        postResumeEvidenceAudioMix = nil
        postResumeEvidenceItem = nil
        postResumeEvidenceTapContext = nil
        postResumeEvidenceTap = nil
        guard let item, let mix else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if item.audioMix === mix { item.audioMix = nil }
            }
        } else {
            DispatchQueue.main.async {
                if item.audioMix === mix { item.audioMix = nil }
            }
        }
    }
    #endif

    private func durationMs(for targetId: String) -> Int? {
        #if canImport(AVFoundation)
        // Publisher/feed duration is useful before AVPlayer has loaded the
        // asset, but it is only metadata. Once the active player exposes a
        // finite duration, that transport observation is authoritative and
        // must be allowed to replace an underestimated cached value.
        if activeTargetId == targetId,
           let duration = player?.currentItem?.duration.seconds,
           duration.isFinite,
           duration > 0 {
            let observedMs = Int((duration * 1_000).rounded())
            knownDurations[targetId] = observedMs
            return observedMs
        }
        #endif
        if let known = knownDurations[targetId] {
            return known
        }
        if mediaContext?.targetId == targetId, let durationMs = mediaContext?.durationMs {
            knownDurations[targetId] = durationMs
            return durationMs
        }
        return nil
    }

    private func effectivePlaybackComplete(targetId: String) -> Bool {
        #if canImport(AVFoundation)
        let playerIsPaused = player?.timeControlStatus == .paused
        #else
        let playerIsPaused = paused
        #endif
        return MediaPlaybackCompletionPolicy.reachedEffectiveEnd(
            completionNotificationObserved: playbackComplete,
            targetMatches: (playbackComplete ? completedTargetId : activeTargetId) == targetId,
            playerIsPaused: playerIsPaused,
            userRequestedPause: paused,
            seekIsPending: mediaSeekLifecycle.pending?.targetId == targetId,
            currentMediaTimeMs: currentMediaTimeMs(),
            durationMs: durationMs(for: targetId)
        )
    }

    #if canImport(AVFoundation)
    private func observeCompletion(for item: AVPlayerItem) {
        // A seek can land between watchdog ticks without ever delivering its completion (#166).
        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped, object: item, queue: .main
        ) { [weak self] notification in
            guard let self, let jumpedItem = notification.object as? AVPlayerItem,
                  self.player?.currentItem === jumpedItem else { return }
            self.abandonOverrunMediaSeek(uptime: ProcessInfo.processInfo.systemUptime, observation: .nativeTimeJump)
        }
        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            #if os(iOS)
            if self?.mixesWithOtherAudio == true, self?.lowersBackgroundAudio == true {
                try? PlaybackAudioSessionPolicy.releaseDucking()
            }
            #endif
            self?.playbackComplete = true
            self?.completedTargetId = self?.activeTargetId
            self?.paused = true
            self?.publishNowPlaying(isPlaying: false)
        }
    }

    private func removeCompletionObserver() {
        if let timeJumpObserver {
            NotificationCenter.default.removeObserver(timeJumpObserver)
            self.timeJumpObserver = nil
        }
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
            let status = player.timeControlStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .playing:
                    self.finishPlaybackStartTrace(player: player)
                    self.publishNowPlaying(isPlaying: !self.paused)
                case .paused:
                    // `paused` tracks user intent. A transient AVPlayer pause must
                    // not turn an active session into a canonical user pause or
                    // withdraw its lock-screen playback metadata.
                    let reachedEnd = self.activeTargetId.map { self.effectivePlaybackComplete(targetId: $0) } ?? false
                    self.publishNowPlaying(isPlaying: !self.paused && !reachedEnd)
                case .waitingToPlayAtSpecifiedRate:
                    self.publishNowPlaying(isPlaying: !self.paused)
                @unknown default:
                    break
                }
            }
        }
    }

    private func removePlayerStateObserver() {
        playerStateObservation?.invalidate()
        playerStateObservation = nil
    }

    private var hasPodcastEvidenceTap: Bool {
        #if canImport(MediaToolbox) && canImport(ShazamKit) && !os(watchOS)
        postResumeEvidenceTapContext != nil
        #else
        false
        #endif
    }

    private func finishPlaybackStartTrace(player: AVPlayer) {
        guard var trace = pendingStartTrace else { return }
        pendingStartTrace = nil
        trace.fields["toPlayingMs"] = String(Int((ProcessInfo.processInfo.systemUptime - trace.startedAt) * 1000))
        trace.fields["seekMs"] = trace.fields["seekMs"] ?? "pending"
        // A new access-log entry after the start means the stream was requested again (for example after a seek).
        let events = player.currentItem?.accessLog()?.events.count ?? 0
        trace.fields["accessLogAdded"] = String(max(0, events - trace.accessLogEvents))
        playbackStartTraceHandler?(trace.fields)
    }

    private func removeTimeObserver() {
        guard let timeObserverToken else { return }
        if let player {
            player.removeTimeObserver(timeObserverToken)
        }
        self.timeObserverToken = nil
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
        let center = audioSessionNotificationCenter
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                self?.pauseForSystemInterruption(awaitsEnd: true)
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                self?.finishSystemInterruption(
                    shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                )
            @unknown default:
                break
            }
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
            self?.pauseForSystemInterruption(awaitsEnd: false)
        })
        #endif
    }

    /// `awaitsEnd` is false for a lost route, which never reports an end: nothing to wait for.
    /// Internal so host tests can stand in for the iOS-only interruption and route-change notifications.
    func pauseForSystemInterruption(awaitsEnd: Bool) {
        let wasPlaying = activeTargetId != nil && !paused
        guard interruptionResumePolicy.began(wasPlaying: wasPlaying) else { return }
        if awaitsEnd {
            // iOS doesn't report the end of a message announcement, so the hold also resumes once the other
            // audio stops (#1434).
            withInterruptionHold { [weak self] hold in
                hold.interruptionBegan(resumeWhenOtherAudioStops: { self?.resumeBecauseOtherAudioStopped() })
            }
        }
        paused = true
        player?.pause()
        #if os(iOS)
        if player != nil, mixesWithOtherAudio, lowersBackgroundAudio { try? PlaybackAudioSessionPolicy.releaseDucking() }
        #endif
        publishNowPlaying(isPlaying: false)
        interruptionHandler?(.began)
    }

    private func finishSystemInterruption(shouldResume: Bool) {
        withInterruptionHold { $0.interruptionEnded() }
        guard interruptionResumePolicy.ended(shouldResume: shouldResume) else { return }
        interruptionHandler?(.endedShouldResume)
    }

    /// The interruption's other audio stopped without iOS reporting an end: resume as an end with "should resume"
    /// would, unless the listener has taken over since (#1434).
    private func resumeBecauseOtherAudioStopped() {
        guard interruptionResumePolicy.ended(shouldResume: true) else { return }
        interruptionHandler?(.endedShouldResume)
    }

    /// The listener's Play, Pause, Stop or a new item replaces an interruption's automatic resume.
    private func cancelAutomaticInterruptionResume() {
        interruptionResumePolicy.cancelAutomaticResume()
        withInterruptionHold { $0.listenerActed() }
    }

    /// The audio-session observers run on the main thread; the hold is main-actor state.
    private func withInterruptionHold(_ work: @escaping @MainActor (InterruptionBackgroundHold) -> Void) {
        guard let hold = interruptionHold else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { work(hold) }
        } else {
            Task { @MainActor in work(hold) }
        }
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
        guard remoteCommandHandlingEnabled else {
            clearNowPlaying()
            return
        }
        guard activeTargetId != nil || mediaContext != nil else { return }
        let targetId = activeTargetId ?? mediaContext?.targetId
        let durationSeconds = targetId.flatMap { durationMs(for: $0) }.map { max(0, Double($0) / 1000) }
        let elapsedSeconds = max(0, Double(currentMediaTimeMs() ?? lastRequestedMediaTimeMs) / 1000)
        let context = mediaContext
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: context?.title ?? "Spoken Margins",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            // The clock runs only once the player is really playing: while it opens the stream or
            // rebuffers it is waiting, and a nonzero rate would advance the Lock Screen clock (#943).
            MPNowPlayingInfoPropertyPlaybackRate: SystemPlaybackPresentation.playerRate(
                isPlayingByIntent: isPlaying,
                isWaitingForPlayer: player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                selectedRate: playbackRate
            ),
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
        NowPlayingInfoOwnership.shared.write(info, as: .mediaPlayer, detail: nowPlayingLedgerDetail())
        configureRemoteCommandAvailability(canSeek: durationSeconds != nil)
        #if canImport(UIKit)
        Task { @MainActor in
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }
        #endif
        #endif
    }

    /// Removes this player's card. A card another writer holds (live speech, a shared Margin) stays: this player
    /// clears on every tick while its remote commands are off, and used to take those cards down with it (#2181).
    private func clearNowPlaying() {
        #if canImport(MediaPlayer) && os(iOS)
        NowPlayingInfoOwnership.shared.clear(as: .mediaPlayer, detail: nowPlayingLedgerDetail())
        #endif
    }

    #if canImport(MediaPlayer) && os(iOS)
    private func nowPlayingLedgerDetail() -> String {
        "targets=\(remoteCommandTargets.count) commands=\(remoteCommandHandlingEnabled ? "on" : "off") player=\(player.map { String($0.timeControlStatus.rawValue) } ?? "none")"
    }
    #endif

    private func installRemoteCommandHandlers() {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        removeRemoteCommandHandlers()

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipBackSeconds)]
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipForwardSeconds)]
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
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
            guard let self else { return .noSuchContent }
            guard let nextTrackHandler = self.nextTrackHandler else {
                return self.dispatchRemoteCommand(.skipForward) ? .success : .noSuchContent
            }
            guard self.activeTargetId != nil else { return .noSuchContent }
            nextTrackHandler()
            return .success
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
        try PlaybackAudioSessionPolicy.ensurePlaybackCategory(
            options: PlaybackAudioSessionPolicy.options(mixes: mixesWithOtherAudio, lowersBackground: lowersBackgroundAudio)
        )
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
    private var remoteCommandHandlingEnabled = true

    public init(speech: AudioPlaybackClient, media: AudioPlaybackClient) {
        self.speech = speech
        self.media = media
        media.setRemoteCommandHandlingEnabled(false)
    }

    public func configureMediaContext(_ context: PlaybackMediaContext?) throws {
        try media.configureMediaContext(context)
        if context == nil {
            media.setRemoteCommandHandlingEnabled(false)
            try speech.configureMediaContext(nil)
        } else {
            media.setRemoteCommandHandlingEnabled(remoteCommandHandlingEnabled)
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
        media.setRemoteCommandHandlingEnabled(false)
        try media.stop()
        try speech.play(targetId: targetId)
    }

    public func play(targetId: String, from charOffset: Int) throws {
        activeRoute = .speech
        media.setRemoteCommandHandlingEnabled(false)
        try media.stop()
        try speech.play(targetId: targetId, from: charOffset)
    }

    public func play(targetId: String, seekingTo charOffset: Int) throws {
        activeRoute = .speech
        media.setRemoteCommandHandlingEnabled(false)
        try media.stop()
        try speech.play(targetId: targetId, seekingTo: charOffset)
    }

    public func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        activeRoute = .media
        try speech.stop()
        media.setRemoteCommandHandlingEnabled(remoteCommandHandlingEnabled)
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

    public func currentRecoveryCharOffset() -> Int? {
        activeRoute == .speech ? speech.currentRecoveryCharOffset() : nil
    }

    public func currentMediaTimeMs() -> Int? {
        activeRoute == .media ? media.currentMediaTimeMs() : nil
    }

    // Podcast anchor evidence comes from the media player's audio. Without explicit
    // forwarding these calls hit the protocol defaults and silently return false.
    @discardableResult
    public func captureBufferedPreInterjectionAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        guard activeRoute == .media else { return false }
        return media.captureBufferedPreInterjectionAudioSample(request)
    }

    @discardableResult
    public func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        guard activeRoute == .media else { return false }
        return media.armPostResumeAudioSample(request)
    }

    public func currentPlaybackDurationMs() -> Int? {
        activeRoute == .media ? media.currentPlaybackDurationMs() : nil
    }

    public func seek(toMediaTimeMs mediaTimeMs: Int) throws {
        activeRoute = .media
        try media.seek(toMediaTimeMs: mediaTimeMs)
    }

    public func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        activeRoute = .media
        return try media.requestMediaSeek(toMediaTimeMs: mediaTimeMs)
    }

    public func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution {
        media.mediaSeekResolution(for: request)
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

    public func currentPlayerRate() -> Double? {
        switch activeRoute {
        case .media: return media.currentPlayerRate()
        case .speech: return speech.currentPlayerRate()
        case nil: return nil
        }
    }

    public func setMixesWithOtherAudio(_ enabled: Bool) throws {
        try speech.setMixesWithOtherAudio(enabled)
        try media.setMixesWithOtherAudio(enabled)
    }

    public func setLowersBackgroundAudio(_ enabled: Bool) throws {
        try speech.setLowersBackgroundAudio(enabled)
        try media.setLowersBackgroundAudio(enabled)
    }

    public func setPlaybackVolume(_ volume: Float) throws {
        try speech.setPlaybackVolume(volume)
        try media.setPlaybackVolume(volume)
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

    public func isAwaitingRenderedAudio(targetId: String) -> Bool {
        activeRoute == .media ? media.isAwaitingRenderedAudio(targetId: targetId)
            : speech.isAwaitingRenderedAudio(targetId: targetId)
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

    public func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        remoteCommandHandlingEnabled = enabled
        switch activeRoute {
        case .speech:
            speech.setRemoteCommandHandlingEnabled(enabled)
            media.setRemoteCommandHandlingEnabled(false)
        case .media:
            speech.setRemoteCommandHandlingEnabled(false)
            media.setRemoteCommandHandlingEnabled(enabled)
        case nil:
            speech.setRemoteCommandHandlingEnabled(false)
            media.setRemoteCommandHandlingEnabled(false)
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

/// Used on the main thread; the audio-session observers run on the main queue.
public final class SystemRecordingClient: RecordingClient, RecordingInterruptionReporting, @unchecked Sendable {
    private var finalizedIntegrity: FinalizedRecordingIntegrity?
    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var recorderDelegate: CaptureDelegate?
    /// The loudest the microphone has been since the Margin began, in dB (diagnostics only, #937).
    private var peakPowerDb: Float?
    /// A Margin is being captured: from `beginRecording` until it is finished or cancelled.
    private var isCaptureActive = false
    private var captureRestarts = 0
    /// The recorder is paused while the ready cue plays (#1594), so the cue is not in the file. It is still a
    /// running capture: the poll reads it as running, and a restart must not replace it.
    private var recorderHeldForCue = false
    /// Names one hold, so a resume timer from an earlier hold or recording can't restart a recorder that was
    /// finished, cancelled, interrupted or replaced in the meantime.
    private var cueHoldToken = 0
    /// The most `currentTime` the current recorder has shown. A stopped `AVAudioRecorder` reads 0, but
    /// the audio it took in is still in its file.
    private var capturedHighWaterMs = 0
    /// The length of a stopped recorder's finalized file, measured once off the main thread. Nil while the
    /// recorder runs. Until it lands, or if the file can't be read, the length is unknown and kept (#937).
    private var stoppedMeasurement: StoppedFileMeasurement?
    /// Chosen at the start of a Margin from the route playback was on, and kept for its restarts (#1506).
    private var inputChoice: RecordingInputChoice = .headsetMicrophoneAllowed
    #endif
    private let fileManager: FileManager
    private let baseDirectory: URL?
    private let deactivateSessionOnFinish: Bool
    private var shouldNotifyOtherAudioOnFinish = false
    private var releasedSessionAtEnd = false
    /// A call, Siri or lost headphones while recording (#771). iOS stops the recorder on its own;
    /// without this the app kept showing "Recording".
    public var onInterruption: (@Sendable (_ event: MarginRecordingInterruptionEvent, _ recordedSeconds: TimeInterval?) -> Void)?
    private let audioSessionNotificationCenter: NotificationCenter
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var recordingStartedAt: Date?
    /// After an interruption stops a recording, its end still decides whether the source resumes.
    private var awaitsInterruptionEnd = false
    /// Headphone outputs in use when the interruption began. A suspended app may miss the route
    /// change during a call, so the end checks they are still there.
    private var headphonesWhenInterrupted: Set<String> = []

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        deactivateSessionOnFinish: Bool = false,
        audioSessionNotificationCenter: NotificationCenter = .default
    ) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        self.deactivateSessionOnFinish = deactivateSessionOnFinish
        self.audioSessionNotificationCenter = audioSessionNotificationCenter
    }

    deinit {
        for observer in audioSessionObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
    }

    public static func requestRecordPermission() async -> Bool {
        #if canImport(AVFoundation)
        #if os(iOS)
        if #available(iOS 17.0, *) {
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
        }
        return await requestLegacyRecordPermission()
        #elseif os(watchOS)
        return await requestLegacyRecordPermission()
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    #if canImport(AVFoundation) && (os(iOS) || os(watchOS))
    private static func requestLegacyRecordPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
    #endif

    #if canImport(AVFoundation)
    /// Puts the session in `playAndRecord`, then starts a recorder on a new file. A restart passes
    /// `cycleSession` to drop and retake the session, which makes iOS settle the route again (#937).
    private func startRecorder(cycleSession: Bool) throws -> (recorder: AVAudioRecorder, url: URL) {
        #if os(iOS) || os(watchOS)
        let session = AVAudioSession.sharedInstance()
        if cycleSession { try? session.setActive(false) }
        #if os(watchOS)
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP])
        #else
        switch inputChoice {
        case .phoneMicrophoneKeepingA2DP:
            // No hands-free profile in the options: the Bluetooth microphone isn't an input, so iOS leaves
            // the headphones on A2DP and records from the phone (#1506).
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        case .headsetMicrophoneAllowed:
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        #endif
        try session.setActive(true)
        #endif
        let directory = try recordingsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "\(stamp)\(captureRestarts == 0 ? "" : "-r\(captureRestarts)").m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        let delegate = CaptureDelegate()
        recorder.delegate = delegate
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw SessionKitError.persistenceFailed("recording_failed")
        }
        recorderDelegate = delegate
        capturedHighWaterMs = 0
        stoppedMeasurement = nil
        recorderHeldForCue = false
        return (recorder, url)
    }

    /// What `AVAudioRecorder` reported when it stopped by itself, kept for the diagnostics log.
    private final class CaptureDelegate: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var finishedSuccessfully: Bool?
        private var encodeError: String?

        func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
            lock.withLock { finishedSuccessfully = flag }
        }

        func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
            lock.withLock { encodeError = error.map { String(describing: type(of: $0)) } ?? "unknown" }
        }

        var fields: [String: String] {
            lock.withLock {
                var result: [String: String] = [:]
                if let finishedSuccessfully { result["recorderFinished"] = finishedSuccessfully ? "ok" : "failed" }
                if let encodeError { result["encodeError"] = encodeError }
                return result
            }
        }
    }
    #endif

    public func beginRecording() throws {
        #if canImport(AVFoundation)
        finalizedIntegrity = nil
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let recordPermission: AVAudioSession.RecordPermission
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                recordPermission = .granted
            case .denied:
                recordPermission = .denied
            case .undetermined:
                recordPermission = .undetermined
            @unknown default:
                recordPermission = .undetermined
            }
        } else {
            recordPermission = session.recordPermission
        }
        switch recordPermission {
        case .granted:
            break
        case .denied:
            throw SessionKitError.persistenceFailed("recording_permission_denied")
        case .undetermined:
            throw SessionKitError.persistenceFailed("recording_permission_required")
        @unknown default:
            throw SessionKitError.persistenceFailed("recording_permission_unknown")
        }
        #elseif os(watchOS)
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            break
        case .denied:
            throw SessionKitError.persistenceFailed("recording_permission_denied")
        case .undetermined:
            throw SessionKitError.persistenceFailed("recording_permission_required")
        @unknown default:
            throw SessionKitError.persistenceFailed("recording_permission_unknown")
        }
        #endif
        captureRestarts = 0
        peakPowerDb = nil
        releasedSessionAtEnd = false
        #if os(iOS) || os(watchOS)
        shouldNotifyOtherAudioOnFinish = session.categoryOptions.contains(.mixWithOthers)
        #endif
        #if os(iOS)
        inputChoice = RecordingInputPolicy.choice(outputPortTypes: session.currentRoute.outputs.map(\.portType.rawValue))
        #else
        inputChoice = .headsetMicrophoneAllowed
        #endif
        let (recorder, url) = try startRecorder(cycleSession: false)
        isCaptureActive = true
        self.recorder = recorder
        self.currentURL = url
        recordingStartedAt = Date()
        awaitsInterruptionEnd = false
        installAudioSessionObservers()
        #else
        throw SessionKitError.persistenceFailed("recording_unavailable")
        #endif
    }

    public func captureReading() -> RecordingCaptureReading? {
        #if canImport(AVFoundation)
        guard isCaptureActive else { return nil }
        // No recorder while a capture is active means a restart failed: report that, not "can't tell".
        guard let recorder else { return RecordingCaptureReading(recorderRunning: false, capturedMs: 0) }
        recorder.updateMeters()
        let peak = recorder.peakPower(forChannel: 0)
        peakPowerDb = max(peakPowerDb ?? peak, peak)
        capturedHighWaterMs = max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded()))
        var durationKnown = true
        if isCapturing(recorder) {
            stoppedMeasurement = nil
        } else {
            // The polls can miss audio taken in just before the stop, and a stopped recorder reads 0. The
            // finalized file says how much it really holds. It is measured once, off the main thread, and
            // until that lands (or if the file can't be read) the length is unknown, which means keep.
            if stoppedMeasurement == nil, let currentURL {
                stoppedMeasurement = StoppedFileMeasurement.start(url: currentURL)
            }
            if case .milliseconds(let fileMs)? = stoppedMeasurement?.outcome {
                capturedHighWaterMs = max(capturedHighWaterMs, fileMs)
            } else {
                durationKnown = false
            }
        }
        #if os(iOS) || os(watchOS)
        let inputRoute: String? = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        #else
        let inputRoute: String? = nil
        #endif
        return RecordingCaptureReading(
            recorderRunning: isCapturing(recorder),
            capturedMs: capturedHighWaterMs,
            durationKnown: durationKnown,
            peakPowerDb: peak,
            inputRoute: inputRoute
        )
        #else
        return nil
        #endif
    }

    public func restartCapture() throws {
        #if canImport(AVFoundation)
        guard isCaptureActive else { throw SessionKitError.invalidCommandForState("restartCapture") }
        let previousURL = currentURL
        // A restart deletes the file, and the poll that asked for it may be old, so work out what the recorder
        // really holds first and refuse to delete audio worth keeping. None of this reads the file on the main
        // thread (#1041). A running recorder says how much it has taken in until the moment it stops. One that
        // had already stopped has a background measurement the poll started; if that hasn't landed, the length
        // is unknown, which means keep.
        let hadStopped = recorder.map { !isCapturing($0) } ?? false
        if let recorder, !hadStopped {
            capturedHighWaterMs = max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded()))
        }
        recorder?.stop()
        switch CaptureRestartGuard.verdict(
            capturedMs: capturedHighWaterMs,
            recorderHadStopped: hadStopped,
            measurement: stoppedMeasurement?.outcome
        ) {
        case .restart:
            break
        case .keepUnknown:
            // The file may hold speech: keep it, never delete on an unfinished or failed read.
            throw SessionKitError.persistenceFailed("recording_unreadable")
        case .keepAudio:
            throw SessionKitError.persistenceFailed("recording_has_audio")
        }
        recorder?.delegate = nil
        recorder = nil
        recorderDelegate = nil
        currentURL = nil
        if let previousURL { try? fileManager.removeItem(at: previousURL) }
        captureRestarts += 1
        // The first restart only replaces the recorder. A second retakes the session too.
        let started = try startRecorder(cycleSession: captureRestarts >= 2)
        recorder = started.recorder
        currentURL = started.url
        #else
        throw SessionKitError.persistenceFailed("recording_restart_unsupported")
        #endif
    }

    public func recordingInProgressRef() -> String? {
        #if canImport(AVFoundation)
        guard isCaptureActive, let currentURL else { return nil }
        return relativeRecordingPath(for: currentURL)
        #else
        return nil
        #endif
    }

    public func captureDiagnostics() -> [String: String] {
        #if canImport(AVFoundation)
        var fields: [String: String] = ["captureRestarts": String(captureRestarts), "inputPolicy": inputChoice.rawValue]
        if let recorder {
            fields["recorderRunning"] = String(isCapturing(recorder))
            fields["capturedMs"] = String(max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded())))
            switch stoppedMeasurement?.outcome {
            case nil: fields["stoppedFile"] = stoppedMeasurement == nil ? "recording" : "measuring"
            case .milliseconds(let fileMs)?: fields["stoppedFile"] = "\(fileMs)ms"
            case .unreadable?: fields["stoppedFile"] = "unreadable"
            }
        }
        if let currentURL, let bytes = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            fields["fileBytes"] = String(bytes)
        }
        if let peakPowerDb { fields["peakDb"] = String(Int(peakPowerDb.rounded())) }
        if let recorderDelegate { fields.merge(recorderDelegate.fields) { current, _ in current } }
        #if os(iOS)
        // The session fields name only the output route; a silent microphone is about the input.
        fields["inputs"] = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
        #endif
        return fields.merging(AudioSessionDiagnostics.fields()) { current, _ in current }
        #else
        return [:]
        #endif
    }

    public func finalizedRecordingIntegrity() -> FinalizedRecordingIntegrity? { finalizedIntegrity }

    public func releasedAudioSessionAtEnd() -> Bool { releasedSessionAtEnd }

    public func pauseForReadyCue() {
        #if canImport(AVFoundation)
        guard isCaptureActive, !recorderHeldForCue, let recorder, recorder.isRecording else { return }
        recorder.pause()
        recorderHeldForCue = true
        cueHoldToken += 1
        #endif
    }

    public func resumeAfterReadyCue(after seconds: TimeInterval) {
        #if canImport(AVFoundation)
        guard recorderHeldForCue else { return }
        guard seconds > 0 else { return resumeHeldRecorder(token: cueHoldToken) }
        let token = cueHoldToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.resumeHeldRecorder(token: token)
        }
        #endif
    }

    #if canImport(AVFoundation)
    /// Running, or held still on purpose for the ready cue: either way the capture is alive.
    private func isCapturing(_ recorder: AVAudioRecorder) -> Bool { recorder.isRecording || recorderHeldForCue }

    private func resumeHeldRecorder(token: Int) {
        guard recorderHeldForCue, token == cueHoldToken else { return }
        recorderHeldForCue = false
        guard isCaptureActive, let recorder else { return }
        recorder.record()
    }

    /// A finish, cancel, interruption or restart ends a hold; the resume timer then does nothing.
    private func dropCueHold() {
        recorderHeldForCue = false
        cueHoldToken += 1
    }
    #endif

    public func finishRecording(audioRef: String?) throws -> String {
        #if canImport(AVFoundation)
        guard let recorder, let currentURL else {
            if let audioRef { return audioRef }
            throw SessionKitError.invalidCommandForState("finishRecording")
        }
        let reportedMs = max(capturedHighWaterMs, Int((recorder.currentTime * 1_000).rounded()))
        isCaptureActive = false
        dropCueHold()
        finalizedIntegrity = RecordingFileFinalizer.finish(url: currentURL, reportedMs: reportedMs) { recorder.stop() }
        recorderDelegate = nil
        self.recorder = nil
        self.currentURL = nil
        recordingEnded()
        #if os(iOS) || os(watchOS)
        if deactivateSessionOnFinish || shouldNotifyOtherAudioOnFinish {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            releasedSessionAtEnd = true
        }
        shouldNotifyOtherAudioOnFinish = false
        #endif
        return relativeRecordingPath(for: currentURL)
        #else
        return audioRef ?? "interjections/system-recording.m4a"
        #endif
    }

    public func cancelRecording() throws {
        #if canImport(AVFoundation)
        finalizedIntegrity = nil
        let url = currentURL
        isCaptureActive = false
        dropCueHold()
        recorderDelegate = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        currentURL = nil
        recordingEnded()
        shouldNotifyOtherAudioOnFinish = false
        if let url {
            try? fileManager.removeItem(at: url)
        }
        #if os(iOS) || os(watchOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        releasedSessionAtEnd = true
        #endif
        #endif
    }

    /// Seconds since recording started, or nil when not recording.
    private var recordedSeconds: TimeInterval? {
        recordingStartedAt.map { max(0, Date().timeIntervalSince($0)) }
    }

    private func recordingEnded() {
        recordingStartedAt = nil
        // Keep listening for the end of an interruption that stopped this recording.
        if !awaitsInterruptionEnd { removeAudioSessionObservers() }
    }

    private func installAudioSessionObservers() {
        removeAudioSessionObservers()
        #if canImport(AVFoundation) && os(iOS)
        let center = audioSessionNotificationCenter
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            switch type {
            case .began:
                // While waiting for an end that may never come, a new interruption is reported
                // too, so the app drops the stale resume.
                guard self.recordingStartedAt != nil || self.awaitsInterruptionEnd else { return }
                self.dropCueHold() // iOS has stopped the recorder: a held one must not be restarted into the call
                if !self.awaitsInterruptionEnd { self.headphonesWhenInterrupted = Self.headphoneOutputs() }
                self.awaitsInterruptionEnd = true
                self.onInterruption?(.interruptionBegan, self.recordedSeconds)
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                let wasAwaiting = self.awaitsInterruptionEnd
                self.awaitsInterruptionEnd = false
                if self.recordingStartedAt == nil { self.removeAudioSessionObservers() }
                guard wasAwaiting else { return }
                if !self.headphonesWhenInterrupted.isSubset(of: Self.headphoneOutputs()) {
                    self.onInterruption?(.routeLost, self.recordedSeconds)
                }
                self.headphonesWhenInterrupted = []
                self.onInterruption?(.interruptionEnded(shouldResume: shouldResume), self.recordedSeconds)
            @unknown default:
                break
            }
        })
        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Also while a call that stopped a Margin is on: lost headphones cancel its resume.
            guard let self, self.recordingStartedAt != nil || self.awaitsInterruptionEnd,
                  let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
            self.onInterruption?(.routeLost, self.recordedSeconds)
        })
        #endif
    }

    #if canImport(AVFoundation) && os(iOS)
    /// By name: AirPods change port (and UID) between music and a call's two-way profile.
    private static func headphoneOutputs() -> Set<String> {
        let headphoneTypes: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio]
        return Set(AVAudioSession.sharedInstance().currentRoute.outputs.filter { headphoneTypes.contains($0.portType) }.map(\.portName))
    }
    #endif

    private func removeAudioSessionObservers() {
        for observer in audioSessionObservers {
            audioSessionNotificationCenter.removeObserver(observer)
        }
        audioSessionObservers.removeAll()
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
    private struct PreparedAudioChunk {
        var url: URL
        var offsetMs: Int
    }

    private struct PreparedAudioChunks {
        var chunks: [PreparedAudioChunk]
        var cleanupDirectory: URL?
    }

    private let fileManager: FileManager
    private let baseDirectory: URL?

    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func transcribe(audioPath: String) async throws -> String {
        try await transcribeAligned(audioPath: audioPath).text
    }

    public func transcribeAligned(audioPath: String) async throws -> AlignedInterjectionTranscript {
        #if canImport(Speech)
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw SessionKitError.persistenceFailed("speech_recognition_not_authorized")
        }
        let url = try audioURL(for: audioPath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionKitError.persistenceFailed("audio_file_missing")
        }
        #if canImport(AVFoundation)
        if #available(iOS 26.0, macOS 26.0, *),
           await longFormSpeechTranscriptionIsSupported() {
            return try await transcribeLongFormAudioAligned(at: url)
        }
        #endif
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SessionKitError.persistenceFailed("on_device_speech_recognition_unavailable")
        }
        let prepared = try await prepareAudioChunks(for: url)
        defer {
            if let cleanupDirectory = prepared.cleanupDirectory {
                try? fileManager.removeItem(at: cleanupDirectory)
            }
        }
        var stitchedText = ""
        var stitchedSegments: [AlignedTranscriptSegment] = []
        for (chunkIndex, chunk) in prepared.chunks.enumerated() {
            var chunkTranscript: AlignedInterjectionTranscript?
            var lastRecognitionError: Error?
            for attempt in 0..<2 {
                do {
                    chunkTranscript = try await recognizeAudioAligned(at: chunk.url, recognizer: recognizer)
                } catch {
                    lastRecognitionError = error
                }
                if chunkTranscript?.text.isEmpty == false { break }
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            guard let chunkTranscript, !chunkTranscript.text.isEmpty else {
                if let lastRecognitionError { throw lastRecognitionError }
                throw SessionKitError.persistenceFailed(
                    "interjection_audio_chunk_empty(index=\(chunkIndex + 1),count=\(prepared.chunks.count))"
                )
            }
            stitchedText = stitchedText.isEmpty
                ? chunkTranscript.text
                : "\(stitchedText) \(chunkTranscript.text)"
            for segment in chunkTranscript.segments {
                stitchedSegments.append(AlignedTranscriptSegment(
                    id: "seg-\(String(format: "%06d", stitchedSegments.count + 1))",
                    text: segment.text,
                    startMs: chunk.offsetMs + segment.startMs,
                    endMs: chunk.offsetMs + segment.endMs,
                    confidence: segment.confidence,
                    recognitionChunkId: "chunk-\(String(format: "%04d", chunkIndex + 1))",
                    chunkOffsetMs: chunk.offsetMs
                ))
            }
        }
        if !stitchedText.isEmpty {
            return AlignedInterjectionTranscript(
                text: stitchedText,
                localeIdentifier: recognizer.locale.identifier,
                segments: stitchedSegments
            )
        }
        throw SessionKitError.persistenceFailed(Self.emptyTranscriptEvidence(for: url))
        #else
        throw SessionKitError.persistenceFailed("speech_recognition_unavailable")
        #endif
    }

    #if canImport(Speech)
    #if canImport(AVFoundation)
    @available(iOS 26.0, macOS 26.0, *)
    private func transcribeLongFormAudioAligned(at url: URL) async throws -> AlignedInterjectionTranscript {
        let passages = try await transcribeLongFormSpeechFile(at: url)
        let transcript = passages.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw SessionKitError.persistenceFailed("long_form_speech_transcript_empty")
        }
        var index = 0
        let segments = passages.enumerated().flatMap { passageIndex, passage -> [AlignedTranscriptSegment] in
            let timed = passage.timedText.isEmpty
                ? [LongFormSpeechTimedText(text: passage.text, startMs: passage.startMs, endMs: passage.endMs)]
                : passage.timedText
            return timed.map { timedText in
                index += 1
                return AlignedTranscriptSegment(
                    id: "seg-\(String(format: "%06d", index))",
                    text: timedText.text,
                    startMs: timedText.startMs,
                    endMs: timedText.endMs,
                    confidence: nil,
                    recognitionChunkId: "passage-\(String(format: "%04d", passageIndex + 1))",
                    chunkOffsetMs: passage.startMs
                )
            }
        }
        return AlignedInterjectionTranscript(
            text: transcript,
            localeIdentifier: Locale.current.identifier,
            segments: segments
        )
    }
    #endif

    private func recognizeAudioAligned(
        at url: URL,
        recognizer: SFSpeechRecognizer
    ) async throws -> AlignedInterjectionTranscript? {
        let request = makeOnDeviceSpeechRecognitionRequest(url: url)
        return try await CancellableRecognition.run { finish in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let transcript = result.bestTranscription.formattedString
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let segments = result.bestTranscription.segments.enumerated().compactMap { index, segment -> AlignedTranscriptSegment? in
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        let startMs = max(0, Int((segment.timestamp * 1_000).rounded()))
                        let durationMs = max(1, Int((segment.duration * 1_000).rounded()))
                        return AlignedTranscriptSegment(
                            id: "seg-\(String(format: "%06d", index + 1))",
                            text: text,
                            startMs: startMs,
                            endMs: startMs + durationMs,
                            confidence: Double(segment.confidence)
                        )
                    }
                    finish(.success(transcript.isEmpty ? nil : AlignedInterjectionTranscript(
                        text: transcript,
                        localeIdentifier: recognizer.locale.identifier,
                        segments: segments
                    )))
                    return
                }
                if let error {
                    finish(.failure(error))
                }
            }
            return RecognitionHandle { task.cancel() }
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

    private func prepareAudioChunks(for url: URL) async throws -> PreparedAudioChunks {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw SessionKitError.persistenceFailed("interjection_audio_duration_invalid")
        }
        let durationMs = max(1, Int((durationSeconds * 1000).rounded()))
        let silenceRanges = (try? sustainedSilenceRanges(in: url)) ?? []
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: durationMs,
            silenceRanges: silenceRanges
        )
        guard ranges.count > 1 else {
            return PreparedAudioChunks(chunks: [.init(url: url, offsetMs: 0)], cleanupDirectory: nil)
        }
        let directory = fileManager.temporaryDirectory
            .appending(path: "SpokenMarginsInterjectionTranscriptionV3/\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var chunks: [PreparedAudioChunk] = []
            for (index, range) in ranges.enumerated() {
                let chunkURL = directory.appending(path: "chunk-\(String(format: "%04d", index)).m4a")
                try await exportAudioChunk(
                    asset: asset,
                    startMs: range.startMs,
                    lengthMs: range.lengthMs,
                    outputURL: chunkURL
                )
                chunks.append(.init(url: chunkURL, offsetMs: range.startMs))
            }
            return PreparedAudioChunks(chunks: chunks, cleanupDirectory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        #else
        return PreparedAudioChunks(chunks: [.init(url: url, offsetMs: 0)], cleanupDirectory: nil)
        #endif
    }

    #if canImport(AVFoundation)
    private func exportAudioChunk(asset: AVURLAsset, startMs: Int, lengthMs: Int, outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw SessionKitError.persistenceFailed("interjection_audio_chunk_exporter_unavailable")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: Double(startMs) / 1000, preferredTimescale: 600),
            duration: CMTime(seconds: Double(lengthMs) / 1000, preferredTimescale: 600)
        )
        try await exporter.export(to: outputURL, as: .m4a)
    }
    #endif
    #endif

    private static func emptyTranscriptEvidence(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        #if canImport(AVFoundation)
        if let audioFile = try? AVAudioFile(forReading: url), audioFile.processingFormat.sampleRate > 0 {
            let durationMs = Int((Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1000).rounded())
            return "empty_transcript(duration_ms=\(durationMs),bytes=\(bytes))"
        }
        #endif
        return "empty_transcript(duration_ms=unknown,bytes=\(bytes))"
    }

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
        var lengthMs: Int
        var trimLeadingMs: Int
    }

    public init() {}

    public func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        #if canImport(Speech) && canImport(AVFoundation)
        let status = await requestAuthorization()
        guard status == .authorized else {
            throw SessionKitError.persistenceFailed("speech_recognition_not_authorized")
        }
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            throw SessionKitError.persistenceFailed("source_audio_file_missing")
        }
        if #available(iOS 26.0, macOS 26.0, *),
           await longFormSpeechTranscriptionIsSupported() {
            return try await transcribeLongFormTimeline(
                url: url,
                itemId: itemId,
                timelineDurationMs: durationMs,
                timelineOffsetMs: 0
            )
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SessionKitError.persistenceFailed("on_device_speech_recognition_unavailable")
        }
        let chunks = try await audioChunks(for: url, itemId: itemId, durationMs: durationMs)
        var stitchedSegments: [MediaTimelineSegment] = []
        var stitchedChapters: [MediaTimelineChapter] = []
        var stitchedDurationMs = durationMs
        for chunk in chunks {
            let timeline = try await transcribeChunk(
                chunk,
                itemId: itemId,
                recognizer: recognizer,
                sourceDurationMs: chunk.lengthMs
            )
            guard !timeline.segments.isEmpty else {
                throw SessionKitError.persistenceFailed(
                    "source_audio_chunk_empty(index=\(chunk.index + 1),count=\(chunks.count))"
                )
            }
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
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SessionKitError.persistenceFailed("source_audio_url_unsupported")
        }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            throw SessionKitError.persistenceFailed("source_audio_file_missing")
        }
        let asset = AVURLAsset(url: url)
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
        let directory = SourceTranscriptionCaches.directory(for: .windows, itemId: itemId, cachesDirectory: caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windowDirectory = directory.appending(path: "window-\(anchorMediaTimeMs)-v3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: windowDirectory, withIntermediateDirectories: true)
        let localWindowURL = windowDirectory.appending(path: "source-window.m4a")
        if !FileManager.default.fileExists(atPath: localWindowURL.path) {
            try await exportChunk(
                asset: asset,
                offsetMs: startMs,
                lengthMs: lengthMs,
                outputURL: localWindowURL
            )
        }
        if #available(iOS 26.0, macOS 26.0, *),
           await longFormSpeechTranscriptionIsSupported() {
            return try await transcribeLongFormTimeline(
                url: localWindowURL,
                itemId: itemId,
                timelineDurationMs: durationMs ?? effectiveDurationMs,
                timelineOffsetMs: startMs
            )
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SessionKitError.persistenceFailed("speech_recognizer_unavailable")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SessionKitError.persistenceFailed("on_device_speech_recognition_unavailable")
        }
        let silenceRanges = (try? sustainedSilenceRanges(in: localWindowURL)) ?? []
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: lengthMs,
            silenceRanges: silenceRanges
        )
        let localWindowAsset = AVURLAsset(url: localWindowURL)
        var stitchedSegments: [MediaTimelineSegment] = []
        var stitchedChapters: [MediaTimelineChapter] = []
        for (index, range) in ranges.enumerated() {
            let chunkURL = windowDirectory.appending(path: "chunk-\(String(format: "%04d", index)).m4a")
            if !FileManager.default.fileExists(atPath: chunkURL.path) {
                try await exportChunk(
                    asset: localWindowAsset,
                    offsetMs: range.startMs,
                    lengthMs: range.lengthMs,
                    outputURL: chunkURL
                )
            }
            let chunk = SourceAudioChunk(
                url: chunkURL,
                offsetMs: startMs + range.startMs,
                index: index,
                lengthMs: range.lengthMs,
                trimLeadingMs: 0
            )
            let timeline = try await transcribeChunk(
                chunk,
                itemId: itemId,
                recognizer: recognizer,
                sourceDurationMs: range.lengthMs
            )
            guard !timeline.segments.isEmpty else {
                throw SessionKitError.persistenceFailed(
                    "source_audio_chunk_empty(index=\(index + 1),count=\(ranges.count))"
                )
            }
            let offset = offsetTimeline(timeline, chunk: chunk)
            stitchedSegments.append(contentsOf: offset.segments)
            stitchedChapters.append(contentsOf: offset.chapters)
        }
        return TranscriptTimeline(
            segments: stitchedSegments.sorted { $0.startMs < $1.startMs },
            chapters: stitchedChapters.sorted { $0.startMs < $1.startMs },
            durationMs: durationMs ?? effectiveDurationMs
        )
        #else
        throw SessionKitError.persistenceFailed("speech_recognition_unavailable")
        #endif
    }

    public func transcribeSourceAudioWindowWithEvidence(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> SourceAudioWindowTranscription {
        let timeline = try await transcribeSourceAudioWindow(
            url: url,
            itemId: itemId,
            anchorMediaTimeMs: anchorMediaTimeMs,
            durationMs: durationMs,
            windowBeforeMs: windowBeforeMs,
            windowAfterMs: windowAfterMs
        )
        #if canImport(AVFoundation)
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let localWindowURL = SourceTranscriptionCaches.directory(for: .windows, itemId: itemId, cachesDirectory: caches)
            .appending(path: "window-\(anchorMediaTimeMs)-v3", directoryHint: .isDirectory)
            .appending(path: "source-window.m4a")
        let startMs = max(0, anchorMediaTimeMs - windowBeforeMs)
        let endMs = min(durationMs ?? Int.max, anchorMediaTimeMs + windowAfterMs)
        return SourceAudioWindowTranscription(
            timeline: timeline,
            localAudioURL: FileManager.default.fileExists(atPath: localWindowURL.path) ? localWindowURL : nil,
            sourceStartMs: startMs,
            sourceEndMs: max(startMs, endMs),
            provenance: url.isFileURL ? .downloadedSourceReference : .sourceWindowReference
        )
        #else
        return SourceAudioWindowTranscription(
            timeline: timeline,
            localAudioURL: nil,
            sourceStartMs: max(0, anchorMediaTimeMs - windowBeforeMs),
            sourceEndMs: anchorMediaTimeMs + windowAfterMs,
            provenance: .sourceWindowReference
        )
        #endif
    }

    #if canImport(Speech) && canImport(AVFoundation)
    @available(iOS 26.0, macOS 26.0, *)
    private func transcribeLongFormTimeline(
        url: URL,
        itemId: String,
        timelineDurationMs: Int?,
        timelineOffsetMs: Int
    ) async throws -> TranscriptTimeline {
        let passages = try await transcribeLongFormSpeechFile(at: url)
        var segments: [MediaTimelineSegment] = []
        for passage in passages {
            let timedText = passage.timedText.isEmpty
                ? [LongFormSpeechTimedText(
                    text: passage.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startMs: passage.startMs,
                    endMs: passage.endMs
                )]
                : passage.timedText
            for timed in timedText where !timed.text.isEmpty {
                let index = segments.count + 1
                segments.append(MediaTimelineSegment(
                    id: "seg-\(String(format: "%06d", index))",
                    startMs: timelineOffsetMs + timed.startMs,
                    endMs: timelineOffsetMs + max(timed.startMs + 1, timed.endMs),
                    text: timed.text
                ))
            }
        }
        guard !segments.isEmpty else {
            throw SessionKitError.persistenceFailed("long_form_source_transcript_empty(item=\(itemId))")
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: timelineDurationMs ?? segments.map(\.endMs).max()
        )
    }

    private func transcribeChunk(
        _ chunk: SourceAudioChunk,
        itemId: String,
        recognizer: SFSpeechRecognizer,
        sourceDurationMs: Int?
    ) async throws -> TranscriptTimeline {
        let request = makeOnDeviceSpeechRecognitionRequest(url: chunk.url)
        // A cancelled task (the job queue's timeout, #1037) must stop the recognizer, or the stuck chunk keeps its slot.
        return try await CancellableRecognition.run { finish in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    finish(.success(Self.timeline(
                        from: result.bestTranscription,
                        itemId: itemId,
                        durationMs: sourceDurationMs
                    )))
                    return
                }
                if let error {
                    finish(.failure(error))
                }
            }
            return RecognitionHandle { task.cancel() }
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
        let silenceRanges = (try? sustainedSilenceRanges(in: localURL)) ?? []
        let ranges = silenceAwareSpeechAudioChunkRanges(
            durationMs: effectiveDurationMs,
            silenceRanges: silenceRanges
        )
        guard ranges.count > 1 else {
            return [SourceAudioChunk(
                url: localURL,
                offsetMs: 0,
                index: 0,
                lengthMs: effectiveDurationMs,
                trimLeadingMs: 0
            )]
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = SourceTranscriptionCaches.directory(for: .chunks, itemId: itemId, cachesDirectory: caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var chunks: [SourceAudioChunk] = []
        for (index, range) in ranges.enumerated() {
            let chunkURL = directory.appending(path: "chunk-\(String(format: "%04d", index)).m4a")
            if !FileManager.default.fileExists(atPath: chunkURL.path) {
                try await exportChunk(
                    asset: asset,
                    offsetMs: range.startMs,
                    lengthMs: range.lengthMs,
                    outputURL: chunkURL
                )
            }
            chunks.append(SourceAudioChunk(
                url: chunkURL,
                offsetMs: range.startMs,
                index: index,
                lengthMs: range.lengthMs,
                trimLeadingMs: 0
            ))
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
        let segments = timeline.segments.compactMap { segment -> MediaTimelineSegment? in
            guard segment.startMs >= chunk.trimLeadingMs else { return nil }
            return MediaTimelineSegment(
                id: "\(prefix)-\(segment.id)",
                startMs: chunk.offsetMs + segment.startMs,
                endMs: chunk.offsetMs + segment.endMs,
                startChar: segment.startChar,
                endChar: segment.endChar,
                text: segment.text
            )
        }
        let chapters = timeline.chapters.compactMap { chapter -> MediaTimelineChapter? in
            guard chapter.startMs >= chunk.trimLeadingMs else { return nil }
            return MediaTimelineChapter(
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
                chapters: [],
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
            chapters: [],
            durationMs: durationMs
        )
    }
    #endif
}
