import Foundation

@MainActor
public final class StreamingSpeechQueue {
    public struct PlaybackObservation: Equatable {
        public enum Event: Equatable {
            case started
            case progressed
            case failed
        }

        public var event: Event
        public var turnId: String
        public var charOffset: Int

        public init(event: Event, turnId: String, charOffset: Int) {
            self.event = event
            self.turnId = turnId
            self.charOffset = charOffset
        }
    }

    private struct Unit: Equatable {
        var turnId: String
        var ordinal: Int
        var startOffset: Int
        var text: String
    }

    private var speech: AudioPlaybackClient
    private var pending: [Unit] = []
    private var current: Unit?
    private var nextOrdinalByTurn: [String: Int] = [:]
    private var nextCharacterOffsetByTurn: [String: Int] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    public private(set) var isPausedForInterjection = false
    public var onTurnDrained: ((String) -> Void)?
    public var onPlaybackObservation: ((PlaybackObservation) -> Void)?

    /// `speech` is the app's shared speech client; the app passes `SystemSpeechPlaybackClient()` (SessionKitAudio).
    public init(speech: AudioPlaybackClient) {
        self.speech = speech
    }

    public var pendingCount: Int { pending.count + (current == nil ? 0 : 1) }
    public var currentTurnId: String? { current?.turnId ?? pending.first?.turnId }
    public var currentSentenceStartOffset: Int? { current?.startOffset ?? pending.first?.startOffset }
    public var currentPresentationOffset: Int? {
        guard let current else { return pending.first?.startOffset }
        return current.startOffset + max(0, speech.currentCharOffset() ?? 0)
    }
    public var currentRecoveryOffset: Int? {
        guard let current else { return pending.first?.startOffset }
        return current.startOffset + max(0, speech.currentRecoveryCharOffset() ?? 0)
    }

    public func hasPendingSpeech(for turnId: String) -> Bool {
        current?.turnId == turnId || pending.contains(where: { $0.turnId == turnId })
    }

    public func configureSpeechClient(_ speech: AudioPlaybackClient) {
        stopAndClear()
        self.speech = speech
    }

    public func enqueue(_ texts: [String], turnId: String) {
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

    public func pauseForInterjection() {
        guard !isPausedForInterjection else { return }
        // The speech client is the shared audio router. Stopping it when no streamed unit is speaking also stops a
        // playing podcast, discarding its player, audio tap and buffer, so every Margin lost its anchor evidence
        // and resumed from a fresh stream request. Only stop speech this queue is actually driving.
        let ownsSpeech = current != nil || worker != nil
        isPausedForInterjection = true
        worker?.cancel()
        worker = nil
        if let current {
            pending.insert(current, at: 0)
            self.current = nil
        }
        if ownsSpeech { try? speech.stop() }
    }

    /// Cancels streamed-unit ownership after the canonical session has handled a
    /// transport command. The shared speech client is deliberately left alone:
    /// it now belongs to SessionEngine, which may have paused or replaced its
    /// current item as part of the same command.
    public func relinquishToCanonicalPlayback() {
        generation += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        current = nil
        nextOrdinalByTurn.removeAll()
        nextCharacterOffsetByTurn.removeAll()
        isPausedForInterjection = false
    }

    public func resumeAfterInterjection() {
        guard isPausedForInterjection else { return }
        isPausedForInterjection = false
        startWorkerIfNeeded()
    }

    public func stopAndClear() {
        generation += 1
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
        let workerGeneration = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  workerGeneration == self.generation,
                  !self.isPausedForInterjection,
                  !self.pending.isEmpty {
                let unit = self.pending.removeFirst()
                self.current = unit
                let targetId = "stream:\(unit.turnId):\(unit.ordinal)"
                do {
                    _ = try self.speech.prepareSpeechText(unit.text)
                    try self.speech.play(targetId: targetId)
                    var playbackStarted = false
                    while !Task.isCancelled,
                          workerGeneration == self.generation,
                          !self.isPausedForInterjection,
                          !playbackStarted {
                        switch self.speech.playbackStartStatus(targetId: targetId) {
                        case .confirmed:
                            playbackStarted = true
                            self.onPlaybackObservation?(
                                PlaybackObservation(event: .started, turnId: unit.turnId, charOffset: unit.startOffset)
                            )
                        case .pending:
                            try? await Task.sleep(for: .milliseconds(50))
                        case .failed:
                            throw SessionKitError.invalidCommandForState("streaming_speech_start_failed")
                        }
                    }
                    guard playbackStarted else {
                        if self.current == unit {
                            self.current = nil
                        }
                        break
                    }
                    while !Task.isCancelled,
                          workerGeneration == self.generation,
                          !self.isPausedForInterjection,
                          !self.speech.isPlaybackComplete(targetId: targetId) {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if !Task.isCancelled, workerGeneration == self.generation {
                        self.onPlaybackObservation?(
                            PlaybackObservation(
                                event: .progressed,
                                turnId: unit.turnId,
                                charOffset: unit.startOffset + unit.text.count
                            )
                        )
                    }
                } catch {
                    self.onPlaybackObservation?(
                        PlaybackObservation(event: .failed, turnId: unit.turnId, charOffset: unit.startOffset)
                    )
                    // The persisted turn remains playable even if immediate speech fails.
                }
                guard workerGeneration == self.generation else { return }
                if self.current == unit {
                    self.current = nil
                }
                if !self.hasPendingSpeech(for: unit.turnId) {
                    self.onTurnDrained?(unit.turnId)
                }
            }
            guard workerGeneration == self.generation else { return }
            self.worker = nil
            if !self.isPausedForInterjection, !self.pending.isEmpty {
                self.startWorkerIfNeeded()
            }
        }
    }
}
