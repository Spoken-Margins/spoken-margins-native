import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

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
        let durationMs = max(1, Int((durationSeconds * 1000).rounded()))
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
            let insertionTime = CMTimeSubtract(
                cursor,
                CMTime(milliseconds: overlapMs)
            )
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
        return max(1, Int((CMTimeGetSeconds(cursor) * 1000).rounded()))
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
