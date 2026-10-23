import Combine
import Foundation
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// Samples the app's memory use into Diagnostics as `memoryFootprint` (#122): at launch, when an item
/// starts playing, when playback moves to another item, at the first playback update a minute after the
/// last sample, and on each memory warning. The samples are saved after each one, so the samples taken
/// before an out-of-memory kill can still be read after the relaunch. It watches the model from outside,
/// so `Gate1AppModel` doesn't grow.
@MainActor
final class MemoryFootprintRecorder {
    struct Reading: Equatable {
        let footprintBytes: UInt64
        let availableBytes: UInt64?
    }

    static let diagnosticsKey = "memoryFootprint"

    private(set) var log: MemoryFootprintLog
    private let diagnostics: PinnedDiagnostics
    private let fileURL: URL?
    private let read: () -> Reading?
    private let now: () -> Date
    private var subscriptions: Set<AnyCancellable> = []

    init(
        diagnostics: PinnedDiagnostics,
        fileURL: URL?,
        read: @escaping () -> Reading? = MemoryFootprintRecorder.readCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.diagnostics = diagnostics
        self.fileURL = fileURL
        self.read = read
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(MemoryFootprintLog.self, from: data) {
            log = saved
        } else {
            log = MemoryFootprintLog()
        }
    }

    static let defaultFileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("DeveloperDiagnostics/memory-footprint.json")

    nonisolated static func readCurrent() -> Reading? {
        guard let footprint = MemoryFootprintReader.footprintBytes() else { return nil }
        return Reading(footprintBytes: footprint, availableBytes: MemoryFootprintReader.availableBytes())
    }

    /// Records the launch sample, then follows the model's playback and the system's memory warnings.
    func start(observing model: Gate1AppModel) {
        record(.launch, mediaType: nil)
        model.playbackClock.snapshots
            .sink { [weak self, weak model] snapshot in
                guard let self, let model else { return }
                self.observe(snapshot, mediaType: { model.libraryItems.first { $0.id == snapshot.itemId }?.mediaType })
            }
            .store(in: &subscriptions)
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self, weak model] _ in
                guard let self else { return }
                let itemId = model?.snapshot.itemId
                self.record(.memoryWarning, mediaType: model?.libraryItems.first { $0.id == itemId }?.mediaType)
            }
            .store(in: &subscriptions)
        #endif
    }

    func observe(_ snapshot: SessionSnapshot, mediaType: () -> String?) {
        let isPlaying = snapshot.status.isPlaybackActive
        if let event = log.eventForPlayback(itemId: snapshot.itemId, isPlaying: isPlaying) {
            record(event, mediaType: mediaType())
        } else if isPlaying, log.playbackSampleIsDue(at: now()) {
            record(.playback, mediaType: mediaType())
        }
    }

    func record(_ event: MemoryFootprintLog.Event, mediaType: String?) {
        guard let reading = read() else { return }
        log.record(event, mediaType: mediaType, footprintBytes: reading.footprintBytes,
                   availableBytes: reading.availableBytes, at: now())
        diagnostics.set(Self.diagnosticsKey, log.diagnosticsLine)
        save()
    }

    // A few kilobytes at most once a minute, written at once: a kill can follow a memory warning closely.
    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(log) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Diagnostics lines that stay put when the dictionary is replaced: Refresh Diagnostics
/// (`refreshDiagnostics()`) and `resetAndSeed()` assign a whole new one. A missing or changed
/// pinned line is put back on the next main-queue turn, after the replacement is stored.
@MainActor
final class PinnedDiagnostics {
    let diagnostics: RuntimeDiagnostics
    private var pinned: [String: String] = [:]
    private var subscription: AnyCancellable?

    init(diagnostics: RuntimeDiagnostics) {
        self.diagnostics = diagnostics
        subscription = diagnostics.$values
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restore() }
    }

    func set(_ key: String, _ value: String) {
        pinned[key] = value
        diagnostics.values[key] = value
    }

    private func restore() {
        for (key, value) in pinned where diagnostics.values[key] != value {
            diagnostics.values[key] = value
        }
    }
}
