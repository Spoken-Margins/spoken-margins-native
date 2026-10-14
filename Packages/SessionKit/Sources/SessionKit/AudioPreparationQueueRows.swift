import Foundation

public struct AudioPreparationQueueRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let itemId: String
    public let title: String
    public let policy: PreparationJobPolicy
    public let state: PreparedAudioState
    public let completedChunkCount: Int
    public let plannedChunkCount: Int
    public let requestedAt: Date
    public let updatedAt: Date
    public let failureCode: String?
    public let isActivePlaybackItem: Bool
    public let canMoveEarlier: Bool
    public let canMoveLater: Bool

    public init(
        id: String,
        itemId: String,
        title: String,
        policy: PreparationJobPolicy,
        state: PreparedAudioState,
        completedChunkCount: Int,
        plannedChunkCount: Int,
        requestedAt: Date,
        updatedAt: Date,
        failureCode: String?,
        isActivePlaybackItem: Bool,
        canMoveEarlier: Bool,
        canMoveLater: Bool
    ) {
        self.id = id
        self.itemId = itemId
        self.title = title
        self.policy = policy
        self.state = state
        self.completedChunkCount = completedChunkCount
        self.plannedChunkCount = plannedChunkCount
        self.requestedAt = requestedAt
        self.updatedAt = updatedAt
        self.failureCode = failureCode
        self.isActivePlaybackItem = isActivePlaybackItem
        self.canMoveEarlier = canMoveEarlier
        self.canMoveLater = canMoveLater
    }

    public var progress: Double {
        guard plannedChunkCount > 0 else { return 0 }
        return min(1, Double(completedChunkCount) / Double(plannedChunkCount))
    }
}

public struct RecentlyPreparedAudioRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let itemId: String
    public let title: String
    public let completedAt: Date
    public let durationMs: Int

    public init(id: String, itemId: String, title: String, completedAt: Date, durationMs: Int) {
        self.id = id
        self.itemId = itemId
        self.title = title
        self.completedAt = completedAt
        self.durationMs = durationMs
    }
}
