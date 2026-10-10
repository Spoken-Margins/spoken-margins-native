import Foundation
import Combine
import SessionKit

@MainActor
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:]
    private var longestHandOverGap = LongestChunkHandOverGap()

    /// Each playback client only knows its own gaps, and the model builds a new one on a voice or
    /// settings change, so the longest of the run is kept here (#586).
    func recordChunkHandOverGap(_ gap: ChunkHandOverGapRecorder.Gap) {
        if longestHandOverGap.keep(gap) { values["longestChunkHandOverGap"] = gap.summary }
    }
}
