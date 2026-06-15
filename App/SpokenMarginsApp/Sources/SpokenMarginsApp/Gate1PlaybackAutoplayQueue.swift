import Foundation
import SessionKit

struct Gate1PlaybackAutoplayQueue {
    private(set) var pendingTurnIds: [String] = []

    var first: String? {
        pendingTurnIds.first
    }

    var count: Int {
        pendingTurnIds.count
    }

    mutating func enqueue(_ turnId: String) {
        guard !pendingTurnIds.contains(turnId) else { return }
        pendingTurnIds.append(turnId)
    }

    mutating func clear() {
        pendingTurnIds.removeAll()
    }

    func contains(where predicate: (String) throws -> Bool) rethrows -> Bool {
        try pendingTurnIds.contains(where: predicate)
    }

    func shouldDeferGeneratedTurnPlayback(snapshot: SessionSnapshot, turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        if completedCurrentAudio {
            return false
        }
        return snapshot.status == .playing && snapshot.targetId != turnId
    }

    func shouldPlayPendingTurnNow(snapshot: SessionSnapshot, turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        guard snapshot.targetId != turnId else { return false }
        if completedCurrentAudio {
            return true
        }
        if snapshot.phase == .finished {
            return true
        }
        return snapshot.status != .playing
    }

    mutating func popReadyTurn(snapshot: SessionSnapshot, completedCurrentAudio: Bool = false) -> String? {
        guard let turnId = pendingTurnIds.first,
              shouldPlayPendingTurnNow(snapshot: snapshot, turnId: turnId, completedCurrentAudio: completedCurrentAudio) else {
            return nil
        }
        pendingTurnIds.removeFirst()
        return turnId
    }
}
