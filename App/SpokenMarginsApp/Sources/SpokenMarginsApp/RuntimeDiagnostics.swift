import Foundation
import Combine
import SessionKit

@MainActor
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:] {
        didSet { putBackLongestHandOverGap() }
    }
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
}
