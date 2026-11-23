import Foundation
import SessionKit

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Free space this many bytes "for important usage" on the volume holding `url`. Injected so a test can say "full".
public typealias SpokenNoteCapacityReading = @Sendable (URL) -> Int64?

public enum SpokenNoteCapacity {
    public static let system: SpokenNoteCapacityReading = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// One take as the renderer reads it.
public struct SpokenNoteRenderTake: Sendable {
    public let requested: SpokenNoteWholeAudioLayout.Requested
    public let url: URL
    public let cut: SpokenNoteTakeCut
    public let cutFingerprint: String

    public init(requested: SpokenNoteWholeAudioLayout.Requested, url: URL, cut: SpokenNoteTakeCut, cutFingerprint: String) {
        self.requested = requested
        self.url = url
        self.cut = cut
        self.cutFingerprint = cutFingerprint
    }
}

/// Makes a note's `clean/whole-note.m4a` from its takes and their cuts (#4779 PR 3).
///
/// One composition with one audio track: each kept stretch is laid end to end, in order, with no overlap, and a 10 ms
/// fade down and up at every join. It exports to a temporary file in `clean/` and renames it into place, then saves
/// `clean/whole-note.json`. The takes are only read. It makes nothing again when the takes, the rule and every cut are
/// what the saved layout says.
public struct SpokenNoteCleanRenderer: Sendable {
    public enum RenderError: Error, Equatable {
        case noAudio
        case exportFailed
        case lengthMismatch(expectedMs: Int, exportedMs: Int)
    }

    /// The exported file may differ from the sum of the kept stretches by an AAC frame or two; more means placements
    /// would be wrong.
    public static let lengthToleranceMs = 100
    /// Room asked for beyond the estimated file size.
    public static let spaceMargin = 1.5

    private let capacity: SpokenNoteCapacityReading

    public init(capacity: @escaping SpokenNoteCapacityReading = SpokenNoteCapacity.system) {
        self.capacity = capacity
    }

    public func render(
        takes: [SpokenNoteRenderTake], noteFolder: URL, pausesOnly: SpokenNotePausesOnlyReason? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpokenNoteCleanLayout {
        let requested = takes.map(\.requested)
        let fingerprints = Dictionary(takes.map { ($0.requested.id, $0.cutFingerprint) }, uniquingKeysWith: { first, _ in first })
        let folder = SpokenNoteCleanFiles.folder(inNoteFolder: noteFolder)
        let audio = SpokenNoteCleanFiles.audioURL(inNoteFolder: noteFolder)
        if let saved = SpokenNoteCleanFiles.readLayout(inNoteFolder: noteFolder), saved.matches(requested: requested, cutFingerprints: fingerprints),
           !saved.result.hasAudio || Self.isRegularFile(audio), Self.isSettled(saved.result) {
            progress(1)
            return saved
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.removeStaleTemporaries(in: folder)

        if takes.allSatisfy({ $0.cut.removesNothing }) {
            let total = takes.reduce(0) { $0 + $1.cut.durationMs }
            let layout = SpokenNoteCleanLayout(
                requested: requested, cutFingerprints: fingerprints,
                placements: takes.map { SpokenNoteCleanPlacement(takeId: $0.requested.id, takeStartMs: 0, takeEndMs: $0.cut.durationMs, outputStartMs: 0) },
                durationMs: total, result: .nothingToRemove
            )
            try? FileManager.default.removeItem(at: audio)
            try SpokenNoteCleanFiles.write(layout, to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: noteFolder))
            progress(1)
            return layout
        }

        #if canImport(AVFoundation)
        let keptMs = takes.reduce(0) { $0 + $1.cut.keptMs }
        let recordedMs = takes.reduce(0) { $0 + $1.cut.durationMs }
        if let available = capacity(folder) {
            let needed = Int64(Double(await Self.estimatedBytes(takes: takes, keptMs: keptMs)) * Self.spaceMargin)
            if available < needed {
                return try saveFailure(.noSpace, requested: requested, fingerprints: fingerprints, noteFolder: noteFolder)
            }
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.exportFailed
        }
        var cursor = CMTime.zero
        var placements: [SpokenNoteCleanPlacement] = []
        var joins: [CMTime] = []
        for take in takes {
            let asset = AVURLAsset(url: take.url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let assetDuration = try? await asset.load(.duration) else { continue }
            let assetMs = Self.milliseconds(assetDuration)
            for span in take.cut.kept {
                let start = min(span.startMs, assetMs)
                let end = min(span.endMs, assetMs)
                guard end > start else { continue }
                let range = CMTimeRange(start: CMTime(value: CMTimeValue(start), timescale: 1_000), end: CMTime(value: CMTimeValue(end), timescale: 1_000))
                try track.insertTimeRange(range, of: sourceTrack, at: cursor)
                if cursor > .zero { joins.append(cursor) }
                placements.append(SpokenNoteCleanPlacement(takeId: take.requested.id, takeStartMs: start, takeEndMs: end, outputStartMs: Self.milliseconds(cursor)))
                cursor = CMTimeAdd(cursor, range.duration)
            }
        }
        guard !placements.isEmpty else { throw RenderError.noAudio }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        let fade = CMTime(value: CMTimeValue(SpokenNoteCleanPolicy.fadeMs), timescale: 1_000)
        for join in joins {
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(join, fade), duration: fade))
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: join, duration: fade))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RenderError.exportFailed
        }
        exporter.audioMix = mix
        let temporary = folder.appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString.lowercased()).m4a")
        let monitor = Task {
            for await state in exporter.states(updateInterval: 0.25) {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: temporary, as: .m4a)
            } onCancel: {
                exporter.cancelExport()
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if Self.isInterruption(error) {
                return SpokenNoteCleanLayout(requested: requested, cutFingerprints: fingerprints, placements: [], durationMs: 0, result: .interrupted)
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return try saveFailure(.other, requested: requested, fingerprints: fingerprints, noteFolder: noteFolder)
        }

        let expectedMs = Self.milliseconds(cursor)
        let exportedMs = (try? await AVURLAsset(url: temporary).load(.duration)).map(Self.milliseconds) ?? 0
        guard abs(exportedMs - expectedMs) <= Self.lengthToleranceMs else {
            try? FileManager.default.removeItem(at: temporary)
            throw RenderError.lengthMismatch(expectedMs: expectedMs, exportedMs: exportedMs)
        }
        guard rename(temporary.path, audio.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let saved = max(0, recordedMs - expectedMs)
        let result: SpokenNoteCleanResult = pausesOnly.map { .pausesOnly(reason: $0, savedMs: saved) } ?? .made(savedMs: saved)
        let layout = SpokenNoteCleanLayout(requested: requested, cutFingerprints: fingerprints, placements: placements, durationMs: expectedMs, result: result)
        try SpokenNoteCleanFiles.write(layout, to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: noteFolder))
        progress(1)
        return layout
        #else
        throw RenderError.exportFailed
        #endif
    }

    // MARK: Helpers

    static let temporaryPrefix = "whole-note.tmp-"

    /// A failed or interrupted run is never reused: Try again, or the app coming back, makes it again.
    static func isSettled(_ result: SpokenNoteCleanResult) -> Bool {
        switch result {
        case .failed, .interrupted: return false
        default: return true
        }
    }

    private func saveFailure(
        _ failure: SpokenNoteCleanResult.Failure, requested: [SpokenNoteWholeAudioLayout.Requested],
        fingerprints: [String: String], noteFolder: URL
    ) throws -> SpokenNoteCleanLayout {
        let layout = SpokenNoteCleanLayout(requested: requested, cutFingerprints: fingerprints, placements: [], durationMs: 0, result: .failed(failure))
        try? SpokenNoteCleanFiles.write(layout, to: SpokenNoteCleanFiles.layoutURL(inNoteFolder: noteFolder))
        return layout
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// A render cut short by the app ending leaves its half-made file. One older than an hour belongs to no render still running.
    static func removeStaleTemporaries(in folder: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(temporaryPrefix) {
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > 3_600 else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    #if canImport(AVFoundation)
    /// Kept seconds at the takes' own byte rate (file size over length), so a cut note never needs more than its takes.
    static func estimatedBytes(takes: [SpokenNoteRenderTake], keptMs: Int) async -> Int64 {
        var bytes: Int64 = 0
        var ms = 0
        for take in takes {
            let size = ((try? FileManager.default.attributesOfItem(atPath: take.url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            bytes += size
            ms += take.cut.durationMs
        }
        guard ms > 0 else { return 0 }
        return Int64(Double(bytes) * Double(keptMs) / Double(ms))
    }

    static func isInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AVFoundationErrorDomain && nsError.code == AVError.Code.operationInterrupted.rawValue
    }

    static func milliseconds(_ time: CMTime) -> Int {
        let seconds = time.seconds
        return seconds.isFinite ? max(0, Int((seconds * 1_000).rounded())) : 0
    }
    #endif
}
