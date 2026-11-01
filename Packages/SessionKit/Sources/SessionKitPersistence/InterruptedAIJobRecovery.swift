import Foundation
import SessionKit

extension SQLiteSessionStore {
    /// Settles the AI jobs an earlier run of the app left `pending` or `streaming` (#2506, fix class `summary-read`).
    /// Launch used to walk every Library row, then every session of the row, then load that session's AI jobs (about
    /// 319 `loadSessions(itemId:)` reads for a real Library, nearly all of them for sessions with no job in flight).
    /// This asks the store which sessions hold such a job, in one query that reads a session id and nothing else, and
    /// opens only those.
    ///
    /// A job on the on-device provider becomes `retryable` (`app_terminated_during_stream`); any other provider's job
    /// becomes `failed` (`remote_provider_disabled_by_feature_flag`). A job's turn that was still `streaming` becomes
    /// `failed_partial`. Each session's changes are one transaction, so a job is never settled while its turn is not.
    /// Returns how many jobs it settled. It also settles jobs of deleted items, which the Library walk never reached:
    /// a deleted item's stuck job was never going to run again.
    @discardableResult
    public func settleInterruptedAIJobs() throws -> Int {
        var sessionIds: [String] = []
        try readTexts(
            """
            SELECT DISTINCT session_id FROM records WHERE kind = 'ai_job' AND json_valid(payload)
              AND json_extract(payload, '$.status') IN ('pending', 'streaming')
            ORDER BY session_id;
            """, [], name: "sessions_with_interrupted_ai_jobs"
        ) { sessionIds.append($0) }
        var recovered = 0
        for sessionId in sessionIds {
            recovered += try withTransaction {
                var settled = 0
                for var job in try loadAIJobs(sessionId: sessionId) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = job.providerType != "apple_foundation_on_device"
                    job.status = remoteJobDisabled ? "failed" : "retryable"
                    job.lastError = remoteJobDisabled
                        ? "remote_provider_disabled_by_feature_flag"
                        : "app_terminated_during_stream"
                    try updateAIJob(job)
                    if let turnId = job.turnId,
                       var turn = try loadTurns(sessionId: sessionId).first(where: { $0.id == turnId && $0.status == "streaming" }) {
                        turn.status = "failed_partial"
                        try saveTurn(turn)
                    }
                    settled += 1
                }
                return settled
            }
        }
        return recovered
    }
}
