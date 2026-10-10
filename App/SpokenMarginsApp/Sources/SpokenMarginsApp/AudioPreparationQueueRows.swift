import Foundation
import SessionKit

struct AudioPreparationQueueRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let policy: PreparationJobPolicy
    let state: PreparedAudioState
    let completedChunkCount: Int
    let plannedChunkCount: Int
    let requestedAt: Date
    let updatedAt: Date
    let failureCode: String?
    let isActivePlaybackItem: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    var progress: Double {
        guard plannedChunkCount > 0 else { return 0 }
        return min(1, Double(completedChunkCount) / Double(plannedChunkCount))
    }
}

struct RecentlyPreparedAudioRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let completedAt: Date
    let durationMs: Int
}
