import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Detects acoustic silence from the recording itself, while treating aligned
/// word ranges as protected speech. This catches leading/trailing gaps and room
/// tone that speech-recognition timestamps alone do not describe reliably.
public enum InterjectionSilenceDetector {
    public static let analysisWindowMs = 20
    public static let minimumSilenceMs = 360
    public static let retainedInternalSilenceMs = 140
    public static let retainedEdgeSilenceMs = 80
    public static let protectedSpeechPaddingMs = 50

    public static func proposePauseEdits(
        sourceURL: URL,
        alignedTranscript: AlignedInterjectionTranscript
    ) throws -> [InterjectionCleanupDecision] {
        #if canImport(AVFoundation)
        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0,
              format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(4_096, Int(sampleRate)))
              ) else {
            throw SessionKitError.persistenceFailed("interjection_silence_analysis_format_invalid")
        }
        let framesPerWindow = max(1, Int((sampleRate * Double(analysisWindowMs) / 1_000).rounded()))
        var windowDB: [Double] = []
        var accumulatedSquare = 0.0
        var accumulatedFrames = 0

        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var frameSquare = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let sample = Double(channels[channel][frame])
                    frameSquare += sample * sample
                }
                accumulatedSquare += frameSquare / Double(format.channelCount)
                accumulatedFrames += 1
                if accumulatedFrames == framesPerWindow {
                    windowDB.append(10 * log10(max(1e-12, accumulatedSquare / Double(accumulatedFrames))))
                    accumulatedSquare = 0
                    accumulatedFrames = 0
                }
            }
        }
        if accumulatedFrames > 0 {
            windowDB.append(10 * log10(max(1e-12, accumulatedSquare / Double(accumulatedFrames))))
        }
        guard !windowDB.isEmpty else { return [] }

        let sorted = windowDB.sorted()
        let noiseIndex = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.20).rounded()))
        let silenceThresholdDB = min(-32, max(-50, sorted[noiseIndex] + 8))
        let protected = alignedTranscript.segments.map {
            max(0, $0.startMs - protectedSpeechPaddingMs)..<($0.endMs + protectedSpeechPaddingMs)
        }
        let isSilent = windowDB.indices.map { index -> Bool in
            let start = index * analysisWindowMs
            let end = start + analysisWindowMs
            let overlapsSpeech = protected.contains { $0.lowerBound < end && $0.upperBound > start }
            return !overlapsSpeech && windowDB[index] <= silenceThresholdDB
        }

        let durationMs = Int((Double(file.length) / sampleRate * 1_000).rounded())
        var decisions: [InterjectionCleanupDecision] = []
        var runStart: Int?
        for index in 0...isSilent.count {
            let silent = index < isSilent.count ? isSilent[index] : false
            if silent, runStart == nil {
                runStart = index * analysisWindowMs
            } else if !silent, let start = runStart {
                let end = min(durationMs, index * analysisWindowMs)
                runStart = nil
                guard end - start >= minimumSilenceMs else { continue }
                let removalStart: Int
                let removalEnd: Int
                if start == 0 {
                    removalStart = 0
                    removalEnd = max(0, end - retainedEdgeSilenceMs)
                } else if end >= durationMs - analysisWindowMs {
                    removalStart = min(durationMs, start + retainedEdgeSilenceMs)
                    removalEnd = durationMs
                } else {
                    let flank = retainedInternalSilenceMs / 2
                    removalStart = start + flank
                    removalEnd = end - flank
                }
                guard removalEnd > removalStart else { continue }
                decisions.append(InterjectionCleanupDecision(
                    id: "acoustic-pause-\(removalStart)-\(removalEnd)",
                    kind: .longPause,
                    startMs: removalStart,
                    endMs: removalEnd,
                    accepted: true
                ))
            }
        }
        return decisions
        #else
        return []
        #endif
    }
}

/// Renders a sender-reviewed derivative without mutating the private capture.
/// Adjacent kept ranges overlap briefly so removed fillers and pauses do not
/// create clicks at their edit boundaries.
public enum InterjectionAudioCleanupRenderer {
    public static let crossfadeMs = 15

    public static func render(
        sourceURL: URL,
        destinationURL: URL,
        decisions: [InterjectionCleanupDecision]
    ) async throws -> Int {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw SessionKitError.persistenceFailed("interjection_cleanup_audio_duration_invalid")
        }
        let durationMs = max(1, Int((durationSeconds * 1_000).rounded()))
        let removalRanges = DeterministicInterjectionCleanup.acceptedRemovalRanges(
            decisions: decisions,
            durationMs: durationMs
        )
        let keepRanges = complement(of: removalRanges, durationMs: durationMs)
        guard !keepRanges.isEmpty else {
            throw SessionKitError.persistenceFailed("interjection_cleanup_removed_all_audio")
        }
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SessionKitError.persistenceFailed("interjection_cleanup_audio_track_missing")
        }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var parameters: [AVMutableAudioMixInputParameters] = []
        var previousParameters: AVMutableAudioMixInputParameters?

        for (index, range) in keepRanges.enumerated() {
            guard let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw SessionKitError.persistenceFailed("interjection_cleanup_composition_track_unavailable")
            }
            let rangeDurationMs = range.upperBound - range.lowerBound
            let overlapMs = index == 0 ? 0 : min(crossfadeMs, max(0, rangeDurationMs / 2))
            let insertionTime = CMTimeSubtract(cursor, CMTime(milliseconds: overlapMs))
            let sourceRange = CMTimeRange(
                start: CMTime(milliseconds: range.lowerBound),
                duration: CMTime(milliseconds: rangeDurationMs)
            )
            try track.insertTimeRange(sourceRange, of: sourceTrack, at: insertionTime)

            let input = AVMutableAudioMixInputParameters(track: track)
            if overlapMs > 0 {
                let overlap = CMTime(milliseconds: overlapMs)
                let overlapRange = CMTimeRange(start: insertionTime, duration: overlap)
                input.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: overlapRange)
                previousParameters?.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: overlapRange)
            }
            parameters.append(input)
            previousParameters = input
            cursor = CMTimeAdd(insertionTime, sourceRange.duration)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SessionKitError.persistenceFailed("interjection_cleanup_exporter_unavailable")
        }
        exporter.audioMix = mix
        try await exporter.export(to: destinationURL, as: .m4a)
        return max(1, Int((CMTimeGetSeconds(cursor) * 1_000).rounded()))
        #else
        throw SessionKitError.persistenceFailed("interjection_cleanup_audio_unavailable")
        #endif
    }

    private static func complement(of removals: [Range<Int>], durationMs: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var cursor = 0
        for removal in removals {
            if removal.lowerBound > cursor {
                result.append(cursor..<removal.lowerBound)
            }
            cursor = max(cursor, removal.upperBound)
        }
        if cursor < durationMs {
            result.append(cursor..<durationMs)
        }
        return result.filter { $0.upperBound > $0.lowerBound }
    }
}

#if canImport(CoreMedia)
private extension CMTime {
    init(milliseconds: Int) {
        self.init(value: CMTimeValue(milliseconds), timescale: 1_000)
    }
}
#endif
