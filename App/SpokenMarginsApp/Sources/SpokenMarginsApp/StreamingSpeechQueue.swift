import Foundation
import SessionKitAudio

@MainActor
final class StreamingSpeechQueue {
    private struct Unit: Equatable {
        var turnId: String
        var ordinal: Int
        var startOffset: Int
        var text: String
    }

    private let speech = SystemSpeechPlaybackClient()
    private var pending: [Unit] = []
    private var current: Unit?
    private var nextOrdinalByTurn: [String: Int] = [:]
    private var nextCharacterOffsetByTurn: [String: Int] = [:]
    private var worker: Task<Void, Never>?
    private(set) var isPausedForInterjection = false
    var onTurnDrained: ((String) -> Void)?

    var pendingCount: Int { pending.count + (current == nil ? 0 : 1) }
    var currentTurnId: String? { current?.turnId ?? pending.first?.turnId }
    var currentSentenceStartOffset: Int? { current?.startOffset ?? pending.first?.startOffset }

    func hasPendingSpeech(for turnId: String) -> Bool {
        current?.turnId == turnId || pending.contains(where: { $0.turnId == turnId })
    }

    func enqueue(_ texts: [String], turnId: String) {
        for text in texts {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let ordinal = nextOrdinalByTurn[turnId, default: 0]
            let startOffset = nextCharacterOffsetByTurn[turnId, default: 0]
            nextOrdinalByTurn[turnId] = ordinal + 1
            nextCharacterOffsetByTurn[turnId] = startOffset + normalized.count + 1
            pending.append(Unit(turnId: turnId, ordinal: ordinal, startOffset: startOffset, text: normalized))
        }
        startWorkerIfNeeded()
    }

    func pauseForInterjection() {
        guard !isPausedForInterjection else { return }
        isPausedForInterjection = true
        worker?.cancel()
        worker = nil
        if let current {
            pending.insert(current, at: 0)
            self.current = nil
        }
        try? speech.stop()
    }

    func resumeAfterInterjection() {
        guard isPausedForInterjection else { return }
        isPausedForInterjection = false
        startWorkerIfNeeded()
    }

    func stopAndClear() {
        worker?.cancel()
        worker = nil
        pending.removeAll()
        current = nil
        nextOrdinalByTurn.removeAll()
        nextCharacterOffsetByTurn.removeAll()
        isPausedForInterjection = false
        try? speech.stop()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !isPausedForInterjection, !pending.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.isPausedForInterjection, !self.pending.isEmpty {
                let unit = self.pending.removeFirst()
                self.current = unit
                let targetId = "stream:\(unit.turnId):\(unit.ordinal)"
                do {
                    _ = try self.speech.prepareSpeechText(unit.text)
                    try self.speech.play(targetId: targetId)
                    while !Task.isCancelled,
                          !self.isPausedForInterjection,
                          !self.speech.isPlaybackComplete(targetId: targetId) {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                } catch {
                    // The persisted turn remains playable even if immediate speech fails.
                }
                if self.current == unit {
                    self.current = nil
                }
                if !self.hasPendingSpeech(for: unit.turnId) {
                    self.onTurnDrained?(unit.turnId)
                }
            }
            self.worker = nil
            if !self.isPausedForInterjection, !self.pending.isEmpty {
                self.startWorkerIfNeeded()
            }
        }
    }
}
