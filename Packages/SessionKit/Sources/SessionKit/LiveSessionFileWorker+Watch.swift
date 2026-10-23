import Foundation

/// The phone's side of the Watch contract (#2487 slice 1b; DESIGN section 4): messages from the Watch change the
/// store here, on the worker, and every answer carries the board. Spoken Margins themselves arrive as files and are
/// filed by `fileWatchInbox`; this handles everything else.
extension LiveSessionFileWorker {
    /// Applies one message from the Watch and returns the reply: the phone's clock, the board, and answers for
    /// Margins already filed. Safe to apply twice (each message travels on both lanes).
    public func applyWatch(_ envelope: WatchEnvelope, now: Date = Date()) -> WatchPhoneReply {
        let all = sessions()
        var answers: [WatchMarginAnswer] = []
        var changed: [LiveSession] = []
        switch envelope.message {
        case .hello(let holding):
            answers = holding.compactMap { answerForHeld(id: $0) }
        case .marginDetails(let transfer):
            if let answer = answerForHeld(id: transfer.id) { answers = [answer] }
        case .sessionStart(let info):
            changed = LiveSessionWatchSessions.start(info, clock: envelope.clock, sessions: all, deletions: deletions, now: now)
        case let .sessionEnd(id, endedAt):
            if let ended = LiveSessionWatchSessions.end(id: id, endedAt: endedAt, clock: envelope.clock, sessions: all) {
                changed = [ended]
            }
        case .sessionResume(let id):
            let asked = LiveSessionWatchSessions.phoneTime(envelope.sentAt, clock: envelope.clock).time
            if let resumed = LiveSessionWatchSessions.resume(id: id, at: min(asked, now), sessions: all) { changed = [resumed] }
        case .withdraw(let id):
            withdraw(watchMarginId: id)
        }
        if !changed.isEmpty {
            for session in changed {
                if let before = all[session.id] { noteUnseen(from: before, to: session) }
                unseenLifecycle[session.id] = Lifecycle(session)
            }
            try? persist(changed)
        }
        return WatchPhoneReply(phoneTime: now, board: watchBoard(now: now), answers: answers)
    }

    /// The phone's view for the Watch, sent as the application context.
    public func watchBoard(now: Date = Date()) -> WatchBoard {
        LiveSessionWatchSessions.board(sessions: Array(sessions().values), now: now)
    }

    /// The answer for a Margin the Watch still holds: filed (with where), refused because the listener deleted it
    /// here, or nil when the phone doesn't have it yet, so the Watch sends it again.
    func answerForHeld(id: String) -> WatchMarginAnswer? {
        let transfer = WatchMarginTransfer(id: id, wallStart: Date(timeIntervalSince1970: 1), durationMs: 0)
        let captureId = transfer.captureId
        let sha = openWatchInbox()?.entry(captureId)?.metadata.sha256 ?? ""
        if deletions.marginIds.contains(transfer.marginId) {
            return WatchMarginAnswer(
                receipt: WatchMarginReceipt(captureId: captureId, sha256: sha, status: .duplicate), outcome: .rejected,
                reason: LiveSessionFiling.RejectReason.marginDeleted.words
            )
        }
        guard let holder = sessions().values.first(where: { $0.margins.contains { $0.id == transfer.marginId } }) else { return nil }
        return WatchMarginAnswer(
            receipt: WatchMarginReceipt(captureId: captureId, sha256: sha, status: .duplicate), outcome: .alreadyFiled,
            sessionId: holder.id, filedIn: Self.name(of: holder),
            positionMs: holder.margins.first { $0.id == transfer.marginId }?.sessionOffsetMs
        )
    }

    /// The listener deleted a waiting Margin on the Watch: a copy that arrives later is refused, and one the phone
    /// already filed into a session not yet saved is taken out again.
    func withdraw(watchMarginId id: String) {
        let marginId = WatchMarginTransfer(id: id, wallStart: Date(timeIntervalSince1970: 1), durationMs: 0).marginId
        let all = sessions()
        deletions.marginIds.insert(marginId)
        try? collection?.saveDeletions(deletions)
        guard var holder = all.values.first(where: { $0.savedItemId == nil && $0.margins.contains { $0.id == marginId } }) else { return }
        holder.margins.removeAll { $0.id == marginId }
        noteUnseen(from: all[holder.id] ?? holder, to: holder)
        try? persist([holder])
    }
}
