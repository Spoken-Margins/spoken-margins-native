import AVFoundation
import CryptoKit
import Foundation
import SessionKit
import SessionKitSupertonic

struct SupertonicPreparedChunk: Sendable {
    var startOffset: Int
    var sourceLength: Int
    var text: String
    var boundary: RenderedSpeechChunkBoundary
    var audioURL: URL
}

enum SupertonicPreparedAudioAssembler {
    static func assemble(
        itemId: String,
        sourceText: String,
        projection: NormalizedSpeechText,
        voice: SupertonicVoiceID,
        voiceKey: String? = nil,
        chunks: [SupertonicPreparedChunk],
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) async throws -> PreparedTextAudio {
        let ordered = chunks.sorted { $0.startOffset < $1.startOffset }
        guard !ordered.isEmpty else {
            throw SessionKitError.persistenceFailed("supertonic_prepared_audio_empty")
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var directory = outputDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let signature = signatureFor(sourceText: sourceText, voiceKey: voiceKey ?? voice.rawValue)
        let baseName = "\(safePathComponent(itemId))-\(signature)"
        let destination = outputDirectory.appending(path: "\(baseName).m4a")
        let pcmTemporary = outputDirectory.appending(path: "\(baseName)-\(UUID().uuidString).tmp.caf")
        let encodedTemporary = outputDirectory.appending(path: "\(baseName)-\(UUID().uuidString).tmp.m4a")
        defer {
            try? fileManager.removeItem(at: pcmTemporary)
            try? fileManager.removeItem(at: encodedTemporary)
        }

        let assembled = try writePCM(
            chunks: ordered,
            projection: projection,
            sourceText: sourceText,
            destination: pcmTemporary
        )
        guard let exporter = AVAssetExportSession(
            asset: AVURLAsset(url: pcmTemporary),
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SessionKitError.persistenceFailed("supertonic_m4a_export_unavailable")
        }
        try await exporter.export(to: encodedTemporary, as: .m4a)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: encodedTemporary, to: destination)
        var audio = destination
        var audioValues = URLResourceValues()
        audioValues.isExcludedFromBackup = true
        try? audio.setResourceValues(audioValues)

        let durationMs = assembled.durationMs
        let timeline = TranscriptTimeline(
            segments: assembled.timelineSegments,
            chapters: chapters(from: assembled.timelineSegments),
            durationMs: durationMs
        )
        return PreparedTextAudio(
            normalizedText: sourceText,
            media: ItemMedia(
                sourceType: .generatedTTSPrerendered,
                url: destination.absoluteString,
                durationMs: durationMs,
                nativeMediaId: destination.absoluteString
            ),
            timeline: timeline
        )
    }

    private static func writePCM(
        chunks: [SupertonicPreparedChunk],
        projection: NormalizedSpeechText,
        sourceText: String,
        destination: URL
    ) throws -> (durationMs: Int, timelineSegments: [MediaTimelineSegment]) {
        let source = Array(sourceText)
        let spoken = Array(projection.text)
        let firstInput = try AVAudioFile(forReading: chunks[0].audioURL)
        let output = try AVAudioFile(forWriting: destination, settings: firstInput.processingFormat.settings)
        let outputFormat = output.processingFormat
        var cursorFrames: AVAudioFramePosition = 0
        var timelineSegments: [MediaTimelineSegment] = []
        for chunk in chunks {
            let input = try AVAudioFile(forReading: chunk.audioURL)
            guard input.processingFormat == outputFormat else {
                throw SessionKitError.persistenceFailed("supertonic_chunk_audio_format_mismatch")
            }
            let startFrames = cursorFrames
            cursorFrames += try append(input: input, to: output)
            let startMs = milliseconds(startFrames, sampleRate: outputFormat.sampleRate)
            let endMs = max(startMs + 1, milliseconds(cursorFrames, sampleRate: outputFormat.sampleRate))
            // A chunk that speaks across skipped text (a PDF's references) gets a segment per
            // stretch of Item.text it reads, so positions never land in what wasn't heard (#336).
            let pieces = NarrationTimelinePieces.pieces(
                spokenRange: chunk.startOffset..<(chunk.startOffset + chunk.sourceLength),
                startMs: startMs, endMs: endMs, projection: projection, source: source
            )
            for piece in pieces {
                let lower = min(piece.spokenRange.lowerBound, spoken.count)
                let upper = min(max(lower, piece.spokenRange.upperBound), spoken.count)
                timelineSegments.append(MediaTimelineSegment(
                    id: "supertonic-seg-\(String(format: "%04d", timelineSegments.count + 1))",
                    startMs: piece.startMs,
                    endMs: piece.endMs,
                    startChar: piece.startChar,
                    endChar: piece.endChar,
                    text: pieces.count == 1 ? chunk.text : String(spoken[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            if chunk.boundary.transitionDelay > 0 {
                cursorFrames += try appendSilence(
                    seconds: chunk.boundary.transitionDelay,
                    format: outputFormat,
                    to: output
                )
            }
        }
        return (
            max(1, milliseconds(cursorFrames, sampleRate: outputFormat.sampleRate)),
            timelineSegments
        )
    }

    private static func append(input: AVAudioFile, to output: AVAudioFile) throws -> AVAudioFramePosition {
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity) else {
            throw SessionKitError.persistenceFailed("supertonic_chunk_buffer_unavailable")
        }
        var written: AVAudioFramePosition = 0
        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            buffer.frameLength = 0
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), remaining)))
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
        return written
    }

    private static func appendSilence(
        seconds: TimeInterval,
        format: AVAudioFormat,
        to output: AVAudioFile
    ) throws -> AVAudioFramePosition {
        let frameCount = AVAudioFrameCount(max(0, (seconds * format.sampleRate).rounded()))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return 0
        }
        buffer.frameLength = frameCount
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
        try output.write(from: buffer)
        return AVAudioFramePosition(frameCount)
    }

    private static func milliseconds(_ frames: AVAudioFramePosition, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return Int(((Double(frames) / sampleRate) * 1_000).rounded())
    }

    private static func chapters(from segments: [MediaTimelineSegment]) -> [MediaTimelineChapter] {
        guard !segments.isEmpty else { return [] }
        let stride = max(1, Int((Double(segments.count) / 12.0).rounded(.up)))
        return segments.enumerated().compactMap { index, segment in
            guard index % stride == 0 else { return nil }
            let words = segment.text.split(separator: " ").prefix(7).joined(separator: " ")
            return MediaTimelineChapter(
                id: "ch-supertonic-\(String(format: "%02d", (index / stride) + 1))",
                title: words.isEmpty ? "Chapter \((index / stride) + 1)" : words,
                startMs: segment.startMs,
                transcriptSegmentId: segment.id
            )
        }
    }

    /// `voiceKey` is the Supertonic voice's name for James and Lily, so their files keep the names earlier builds wrote,
    /// and the downloaded voice's saved-audio digest for the others, so one voice never replaces another's file (#2857).
    private static func signatureFor(sourceText: String, voiceKey: String) -> String {
        let payload = "supertonic-prepared-v1\u{1f}\(voiceKey)\u{1f}\(sourceText)"
        return SHA256.hash(data: Data(payload.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func safePathComponent(_ value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(safe).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "item" : String(collapsed.prefix(64))
    }
}
