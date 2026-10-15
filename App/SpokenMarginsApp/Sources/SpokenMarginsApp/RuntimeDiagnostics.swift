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

    /// Each playback client only knows its own gaps, and the model builds a new one on a voice or
    /// settings change, so the longest of the run is kept here (#586).
    func recordChunkHandOverGap(_ gap: ChunkHandOverGapRecorder.Gap) {
        if longestHandOverGap.keep(gap) { values[Self.handOverGapKey] = gap.summary }
    }

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
