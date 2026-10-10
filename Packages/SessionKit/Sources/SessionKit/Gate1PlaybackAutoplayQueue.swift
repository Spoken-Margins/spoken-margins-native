import Foundation

public struct Gate1PlaybackAutoplayQueue {
    public private(set) var pendingTurnIds: [String] = []

    public init() {}

    public var first: String? {
        pendingTurnIds.first
    }

    public var count: Int {
        pendingTurnIds.count
    }

    public mutating func enqueue(_ turnId: String) {
        guard !pendingTurnIds.contains(turnId) else { return }
        pendingTurnIds.append(turnId)
    }

    public mutating func clear() {
        pendingTurnIds.removeAll()
    }

    func contains(where predicate: (String) throws -> Bool) rethrows -> Bool {
        try pendingTurnIds.contains(where: predicate)
    }

    public func shouldDeferGeneratedTurnPlayback(snapshot: SessionSnapshot, turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        if isOriginalContentUnfinished(snapshot) {
            return true
        }
        if completedCurrentAudio {
            return false
        }
        return snapshot.status.isPlaybackActive && snapshot.targetId != turnId
    }

    public func shouldPlayPendingTurnNow(snapshot: SessionSnapshot, turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        guard snapshot.targetId != turnId else { return false }
        if isOriginalContentUnfinished(snapshot) {
            return false
        }
        if completedCurrentAudio {
            return true
        }
        if snapshot.phase == .finished {
            return true
        }
        return !snapshot.status.isPlaybackActive
    }

    public mutating func popReadyTurn(snapshot: SessionSnapshot, completedCurrentAudio: Bool = false) -> String? {
        guard let turnId = pendingTurnIds.first,
              shouldPlayPendingTurnNow(snapshot: snapshot, turnId: turnId, completedCurrentAudio: completedCurrentAudio) else {
            return nil
        }
        pendingTurnIds.removeFirst()
        return turnId
    }

    private func isOriginalContentUnfinished(_ snapshot: SessionSnapshot) -> Bool {
        guard snapshot.sourceProgressPercent < 100 else { return false }
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue,
            TargetType.transcriptBackedMedia.rawValue,
            TargetType.browserOwnedMedia.rawValue:
            return snapshot.phase != .finished
        default:
            return false
        }
    }
}
