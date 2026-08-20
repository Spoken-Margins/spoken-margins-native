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
        chunks: [SupertonicPreparedChunk],
        outputDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> PreparedTextAudio {
        let ordered = chunks.sorted { $0.startOffset < $1.startOffset }
        guard !ordered.isEmpty else {
            throw SessionKitError.persistenceFailed("supertonic_prepared_audio_empty")
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var directory = outputDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let signature = signatureFor(sourceText: sourceText, voice: voice)
        let baseName = "\(safePathComponent(itemId))-\(signature)"
        let destination = outputDirectory.appending(path: "\(baseName).caf")
        let temporary = outputDirectory.appending(path: "\(baseName)-\(UUID().uuidString).tmp.caf")
        defer { try? fileManager.removeItem(at: temporary) }

        let firstInput = try AVAudioFile(forReading: ordered[0].audioURL)
        let output = try AVAudioFile(forWriting: temporary, settings: firstInput.processingFormat.settings)
        let outputFormat = output.processingFormat
        var cursorFrames: AVAudioFramePosition = 0
        var timelineSegments: [MediaTimelineSegment] = []

        for (index, chunk) in ordered.enumerated() {
            let input = try AVAudioFile(forReading: chunk.audioURL)
            guard input.processingFormat == outputFormat else {
                throw SessionKitError.persistenceFailed("supertonic_chunk_audio_format_mismatch")
            }
            let startFrames = cursorFrames
            cursorFrames += try append(input: input, to: output)
            let startMs = milliseconds(startFrames, sampleRate: outputFormat.sampleRate)
            let endMs = max(startMs + 1, milliseconds(cursorFrames, sampleRate: outputFormat.sampleRate))
            timelineSegments.append(MediaTimelineSegment(
                id: "supertonic-seg-\(String(format: "%04d", index + 1))",
                startMs: startMs,
                endMs: endMs,
                startChar: projection.sourceOffset(atSpokenCharacterOffset: chunk.startOffset),
                endChar: projection.sourceOffset(
                    atSpokenCharacterOffset: chunk.startOffset + chunk.sourceLength
                ),
                text: chunk.text
            ))
            if chunk.boundary.transitionDelay > 0 {
                cursorFrames += try appendSilence(
                    seconds: chunk.boundary.transitionDelay,
                    format: outputFormat,
                    to: output
                )
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
        var audio = destination
        var audioValues = URLResourceValues()
        audioValues.isExcludedFromBackup = true
        try? audio.setResourceValues(audioValues)

        let durationMs = max(1, milliseconds(cursorFrames, sampleRate: outputFormat.sampleRate))
        let timeline = TranscriptTimeline(
            segments: timelineSegments,
            chapters: chapters(from: timelineSegments),
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

    private static func signatureFor(sourceText: String, voice: SupertonicVoiceID) -> String {
        let payload = "supertonic-prepared-v1\u{1f}\(voice.rawValue)\u{1f}\(sourceText)"
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
