import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(CryptoKit)
import CryptoKit
#endif

struct WatchPackageRenderSegment: Equatable {
    var id: String
    var startChar: Int
    var endChar: Int
    var text: String
}

struct WatchPackageRenderPlan: Equatable {
    var packageId: String
    var audioAssetId: String
    var fileName: String
    var segments: [WatchPackageRenderSegment]

    static func make(item: Item, map: ListeningMap?, createdAt: Date = Date()) -> WatchPackageRenderPlan {
        let safeItemId = safeIdentifier(item.id.isEmpty ? "item" : item.id)
        let stamp = Int(createdAt.timeIntervalSince1970)
        let packageId = "watch-package-\(safeItemId)-\(stamp)"
        return WatchPackageRenderPlan(
            packageId: packageId,
            audioAssetId: "audio-\(safeItemId)-prerendered-\(stamp)",
            fileName: "\(packageId).m4a",
            segments: segmentText(item.text ?? "", map: map)
        )
    }

    static func makePackage(
        item: Item,
        map: ListeningMap?,
        plan: WatchPackageRenderPlan,
        segmentDurationsMs: [Int],
        audioSHA256: String?,
        createdAt: Date = Date()
    ) -> WatchAudioPackage {
        var currentMs = 0
        let mediaSegments = zip(plan.segments, segmentDurationsMs).map { segment, durationMs in
            defer { currentMs += max(0, durationMs) }
            return MediaTimelineSegment(
                id: segment.id,
                startMs: currentMs,
                endMs: currentMs + max(0, durationMs),
                startChar: segment.startChar,
                endChar: segment.endChar,
                text: segment.text
            )
        }
        let durationMs = mediaSegments.last?.endMs ?? 0
        return WatchAudioPackage(
            id: plan.packageId,
            itemId: item.id,
            sessionId: "session-watch-\(plan.packageId)",
            createdAt: createdAt,
            item: WatchPackageItem(
                title: item.title,
                mediaType: item.mediaType == "transcript_backed_media" ? "transcript_backed_media" : "text",
                externalReference: item.externalReference
            ),
            audioAssets: [
                WatchPackageAudioAsset(
                    audioAssetId: plan.audioAssetId,
                    fileName: plan.fileName,
                    durationMs: durationMs,
                    sha256: audioSHA256
                )
            ],
            transcript: WatchPackageTranscript(
                transcriptId: "transcript-\(plan.packageId)",
                segments: mediaSegments
            ),
            chapters: chapterTimings(map: map, mediaSegments: mediaSegments),
            settings: WatchPackageSettings(rollbackUnit: "previous_segment", defaultPlaybackRate: 1)
        )
    }

    private static func segmentText(_ text: String, map: ListeningMap?) -> [WatchPackageRenderSegment] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return []
        }
        let chapterSegments = map?.chapters
            .sorted { $0.startChar < $1.startChar }
            .compactMap { chapter -> WatchPackageRenderSegment? in
                let start = max(0, min(chapter.startChar, text.count))
                let end = max(start, min(chapter.endChar, text.count))
                guard end > start else { return nil }
                let chunk = substring(text, start: start, end: end).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !chunk.isEmpty else { return nil }
                return WatchPackageRenderSegment(
                    id: "seg-\(safeIdentifier(chapter.id))",
                    startChar: start,
                    endChar: end,
                    text: chunk
                )
            } ?? []
        if !chapterSegments.isEmpty {
            return chapterSegments
        }
        return sentenceSegments(text)
    }

    private static func sentenceSegments(_ text: String) -> [WatchPackageRenderSegment] {
        var segments: [WatchPackageRenderSegment] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if ".!?\n".contains(character) || next == text.endIndex {
                let rawRange = start..<next
                let raw = String(text[rawRange])
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty,
                   let trimmedRange = raw.range(of: trimmed) {
                    let rawStart = text.distance(from: text.startIndex, to: rawRange.lowerBound)
                    let absoluteStart = rawStart + raw.distance(from: raw.startIndex, to: trimmedRange.lowerBound)
                    let absoluteEnd = absoluteStart + trimmed.count
                    segments.append(
                        WatchPackageRenderSegment(
                            id: "seg-\(String(format: "%03d", segments.count + 1))",
                            startChar: absoluteStart,
                            endChar: absoluteEnd,
                            text: trimmed
                        )
                    )
                }
                start = next
            }
            index = next
        }
        if segments.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let startChar = text.distance(from: text.startIndex, to: text.range(of: trimmed)?.lowerBound ?? text.startIndex)
            return [WatchPackageRenderSegment(id: "seg-001", startChar: startChar, endChar: startChar + trimmed.count, text: trimmed)]
        }
        return segments
    }

    private static func chapterTimings(map: ListeningMap?, mediaSegments: [MediaTimelineSegment]) -> [MediaTimelineChapter] {
        guard let map, !mediaSegments.isEmpty else {
            return mediaSegments.first.map {
                [MediaTimelineChapter(id: "ch-opening", title: "Opening", startMs: $0.startMs, transcriptSegmentId: $0.id)]
            } ?? []
        }
        return map.chapters.compactMap { chapter in
            guard let segment = mediaSegments.first(where: { ($0.startChar ?? 0) >= chapter.startChar })
                    ?? mediaSegments.last(where: { ($0.startChar ?? 0) <= chapter.startChar })
                    ?? mediaSegments.first else {
                return nil
            }
            return MediaTimelineChapter(
                id: chapter.id,
                title: chapter.title,
                startMs: segment.startMs,
                transcriptSegmentId: segment.id
            )
        }
    }

    private static func substring(_ text: String, start: Int, end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return String(text[lower..<upper])
    }

    private static func safeIdentifier(_ value: String) -> String {
        let replaced = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "value" : replaced
    }
}

struct WatchPackageRenderOutput {
    var package: WatchAudioPackage
    var audioURL: URL
}

final class WatchPackageRenderCoordinator {
    private let outputDirectory: URL
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    init(applicationSupportDirectory: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory, fileManager: FileManager = .default) {
        self.outputDirectory = applicationSupportDirectory
            .appending(path: "SpokenMargins/watch-audio", directoryHint: .isDirectory)
        self.temporaryDirectory = temporaryDirectory
            .appending(path: "SpokenMarginsWatchRender", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    func renderSystemSpeechPackage(
        item: Item,
        map: ListeningMap?,
        voiceIdentifier: String?,
        rate: Float
    ) async throws -> WatchPackageRenderOutput {
        #if canImport(AVFoundation)
        let createdAt = Date()
        let plan = WatchPackageRenderPlan.make(item: item, map: map, createdAt: createdAt)
        guard !plan.segments.isEmpty else {
            throw SessionKitError.invalidCommandForState("watch_package_empty_text")
        }
        let segmentDirectory = temporaryDirectory.appending(path: plan.packageId, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: segmentDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var segmentURLs: [URL] = []
        var durationsMs: [Int] = []
        let renderer = SystemSpeechSegmentRenderer(voiceIdentifier: voiceIdentifier, rate: rate)
        for segment in plan.segments {
            let segmentURL = segmentDirectory.appending(path: "\(segment.id).caf")
            let duration = try await renderer.render(text: segment.text, to: segmentURL)
            segmentURLs.append(segmentURL)
            durationsMs.append(max(1, Int((duration * 1000).rounded())))
        }

        let outputURL = outputDirectory.appending(path: plan.fileName)
        try? fileManager.removeItem(at: outputURL)
        try await Self.exportM4A(segmentURLs: segmentURLs, to: outputURL)
        let sha = try Self.sha256(url: outputURL)
        let package = WatchPackageRenderPlan.makePackage(
            item: item,
            map: map,
            plan: plan,
            segmentDurationsMs: durationsMs,
            audioSHA256: sha,
            createdAt: createdAt
        )
        return WatchPackageRenderOutput(package: package, audioURL: outputURL)
        #else
        throw SessionKitError.persistenceFailed("system_speech_render_unavailable")
        #endif
    }

    #if canImport(AVFoundation)
    private static func exportM4A(segmentURLs: [URL], to outputURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SessionKitError.persistenceFailed("audio_composition_track")
        }
        var cursor = CMTime.zero
        for url in segmentURLs {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else {
                throw SessionKitError.persistenceFailed("audio_segment_track_missing")
            }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: track,
                at: cursor
            )
            cursor = cursor + duration
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SessionKitError.persistenceFailed("m4a_exporter_unavailable")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        try await exporter.export(to: outputURL, as: .m4a)
    }
    #endif

    private static func sha256(url: URL) throws -> String? {
        #if canImport(CryptoKit)
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

#if canImport(AVFoundation)
private final class SystemSpeechSegmentRenderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let voiceIdentifier: String?
    private let rate: Float
    private var synthesizer: AVSpeechSynthesizer?
    private var audioFile: AVAudioFile?
    private var continuation: CheckedContinuation<Double, Error>?
    private var outputURL: URL?

    init(voiceIdentifier: String?, rate: Float) {
        self.voiceIdentifier = voiceIdentifier?.isEmpty == true ? nil : voiceIdentifier
        self.rate = rate
    }

    func render(text: String, to outputURL: URL) async throws -> Double {
        try? FileManager.default.removeItem(at: outputURL)
        let speechText = SpeechTextNormalizer.projectForSystemSpeech(text).text
        guard !speechText.isEmpty else {
            throw SessionKitError.invalidCommandForState("watch_package_segment_empty_after_speech_cleaning")
        }
        guard SpeechTextNormalizer.isSystemSpeechSafe(speechText) else {
            throw SessionKitError.invalidCommandForState("watch_package_segment_unsafe_for_system_speech")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.outputURL = outputURL
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            self.synthesizer = synthesizer
            let utterance = AVSpeechUtterance(string: speechText)
            utterance.rate = rate
            if let voiceIdentifier,
               let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            }
            synthesizer.write(utterance) { [weak self] buffer in
                self?.handle(buffer: buffer, outputURL: outputURL)
            }
        }
    }

    private func handle(buffer: AVAudioBuffer, outputURL: URL) {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
        if pcmBuffer.frameLength == 0 {
            finish()
            return
        }
        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcmBuffer.format.settings,
                    commonFormat: pcmBuffer.format.commonFormat,
                    interleaved: pcmBuffer.format.isInterleaved
                )
            }
            try audioFile?.write(from: pcmBuffer)
        } catch {
            fail(error)
        }
    }

    private func finish() {
        do {
            audioFile = nil
            let duration = try renderedDuration()
            continuation?.resume(returning: duration)
            clear()
        } catch {
            fail(error)
        }
    }

    private func renderedDuration() throws -> Double {
        guard let outputURL else {
            throw SessionKitError.persistenceFailed("speech_segment_missing_output")
        }
        let file = try AVAudioFile(forReading: outputURL)
        guard file.fileFormat.sampleRate > 0 else {
            throw SessionKitError.persistenceFailed("speech_segment_invalid_sample_rate")
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func fail(_ error: Error) {
        continuation?.resume(throwing: error)
        clear()
    }

    private func clear() {
        synthesizer?.delegate = nil
        synthesizer = nil
        continuation = nil
        outputURL = nil
    }
}
#endif
