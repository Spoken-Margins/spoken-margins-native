import Foundation
import Combine
import SessionKit

@MainActor
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:] {
        didSet { putBackLongestHandOverGap(); putBackKept() }
    }
    private var kept: [String: String] = [:]
    private var longestHandOverGap = LongestChunkHandOverGap()
    private static let handOverGapKey = "longestChunkHandOverGap"
    private var preparationRun = AudioPreparationRunTracker()

    /// Each playback client only knows its own gaps, and the model builds a new one on a voice or
    /// settings change, so the longest of the run is kept here (#586).
    func recordChunkHandOverGap(_ gap: ChunkHandOverGapRecorder.Gap) {
        if longestHandOverGap.keep(gap) { values[Self.handOverGapKey] = gap.summary }
    }

    /// The last Make available offline run's cost, one line, kept across Refresh Diagnostics (#3816). It is
    /// written with detailed recording off: it is a few counters, not an event log, and holds no item ids.
    func preparationChunkCommitted(renderMs: Int, thermalAtStart: SpeechThermalLevel, thermalAtEnd: SpeechThermalLevel, at now: Date = Date()) {
        keep(AudioPreparationRunSummary.diagnosticsKey, preparationRun.chunkCommitted(
            renderMs: renderMs, thermalAtStart: thermalAtStart, thermalAtEnd: thermalAtEnd, at: now.timeIntervalSinceReferenceDate))
    }

    func preparationHeatPaused(thermal: SpeechThermalLevel, at now: Date = Date()) {
        keep(AudioPreparationRunSummary.diagnosticsKey, preparationRun.heatPaused(thermal: thermal, at: now.timeIntervalSinceReferenceDate))
    }

    /// The run is over; its line stays until the next run replaces it.
    func preparationRunEnded() { preparationRun.ended() }

    /// Refresh Diagnostics (`refreshDiagnostics()`) and `resetAndSeed()` assign a whole new
    /// dictionary, and a gap no longer than the kept one is never written again.
    private func putBackLongestHandOverGap() {
        guard let summary = longestHandOverGap.gap?.summary, values[Self.handOverGapKey] != summary else { return }
        values[Self.handOverGapKey] = summary
    }

    /// An entry that survives Refresh Diagnostics and `resetAndSeed()`: a log the owner reads after the fact, like
    /// the Margin voice starts and stops (#1671), would otherwise vanish on the very tap that shows it.
    func keep(_ key: String, _ value: String) {
        kept[key] = value
        values[key] = value
    }

    private func putBackKept() {
        for (key, value) in kept where values[key] != value { values[key] = value }
    }
}
