import Foundation

/// An address for one pending attempt. Turn and job IDs alone are only unique within a session.
public struct LocalSummaryRequestOrigin: Equatable, Sendable {
    public let sessionId: String
    public let itemId: String
    public let turnId: String
    let jobId: String
    let attempts: Int
    let sourceInterjectionIds: [String]
    let targetId: String?
    let targetType: String?

    public struct Discarded: Error {}

    init(repository: any SessionRepository, snapshot: SessionSnapshot, itemId: String, turnId: String) throws {
        guard let sessionId = snapshot.sessionId,
              snapshot.itemId == itemId,
              let turn = try repository.loadTurns(sessionId: sessionId).first(where: { $0.id == turnId }),
              let job = try repository.loadAIJobs(sessionId: sessionId).first(where: {
                  $0.turnId == turnId && $0.kind == "interjection_summary" && $0.status == "pending"
              }) else { throw Discarded() }
        self.sessionId = sessionId
        self.itemId = itemId
        self.turnId = turnId
        jobId = job.id
        attempts = job.attempts
        sourceInterjectionIds = turn.sourceInterjectionIds
        targetId = snapshot.targetId
        targetType = snapshot.targetType
        _ = try records(in: repository)
    }

    public func matchesPlayback(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.sessionId == sessionId && snapshot.itemId == itemId
            && snapshot.targetId == targetId && snapshot.targetType == targetType
    }

    private func records(in repository: any SessionRepository) throws -> (ConversationTurn, AIJob) {
        guard let session = try repository.loadSession(id: sessionId), session.itemId == itemId,
              try repository.loadItem(id: itemId).deletedAt == nil,
              let turn = try repository.loadTurns(sessionId: sessionId).first(where: { $0.id == turnId }),
              turn.turnType == "interjection_summary",
              turn.status == "pending" || turn.status == "streaming",
              turn.sourceInterjectionIds == sourceInterjectionIds,
              let job = try repository.loadAIJobs(sessionId: sessionId).first(where: { $0.id == jobId }),
              job.itemId == itemId, job.turnId == turnId, job.kind == "interjection_summary",
              job.status == "pending", job.attempts == attempts else { throw Discarded() }
        let liveIDs = Set(try repository.loadInterjections(sessionId: sessionId).filter { $0.status == "active" }.map(\.id))
        guard sourceInterjectionIds.allSatisfy(liveIDs.contains) else { throw Discarded() }
        return (turn, job)
    }

    func save(repository: any SessionRepository, rawText: String, text: String, summary: String?, chapters: [Chapter]) throws {
        // The app's SQLite repository commits both records together. No late result can recreate an absent turn.
        let write = {
            var (turn, job) = try records(in: repository)
            turn.status = "complete"
            turn.rawText = rawText
            turn.text = text
            turn.summary = summary
            turn.chapters = chapters
            job.status = "complete"
            job.lastError = nil
            try repository.saveTurn(turn)
            try repository.updateAIJob(job)
        }
        if let transactional = repository as? any SessionRepositoryTransaction {
            try transactional.withSessionTransaction(write)
        } else {
            try write()
        }
    }
}
