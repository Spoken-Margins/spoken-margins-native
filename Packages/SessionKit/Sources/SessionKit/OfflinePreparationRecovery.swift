import Foundation

/// Durable retries use the charging-only BGProcessingTask, independently of automatic preparation.
public enum OfflinePreparationRecovery {
    public static let waitingForSystem = "background_time_expired"

    public static func backgroundJobs(
        _ jobs: [AudioPreparationJob], automaticPolicy: AutomaticAudioPreparationPolicy
    ) -> [AudioPreparationJob] {
        jobs.filter { !$0.isCancelled && ($0.policy == .explicit || automaticPolicy == .whileCharging) }
    }

    public static func shouldSchedule(
        jobs: [AudioPreparationJob],
        automaticAudio: AutomaticAudioPreparationPolicy,
        automaticEpisodeMaps: AutomaticEpisodeMapPreparationPolicy
    ) -> Bool {
        automaticAudio == .whileCharging || automaticEpisodeMaps == .whileCharging
            || jobs.contains { !$0.isCancelled && $0.policy == .explicit }
    }

    /// Expiry can happen between renders or while waiting for heat. Record it on every remaining
    /// request, rather than relying on a renderer to notice cancellation. Never change its chunks.
    public static func interruptedJobs(
        _ jobs: [AudioPreparationJob], requests: Set<OfflinePreparationRun.RequestKey>
    ) -> [AudioPreparationJob] {
        jobs.compactMap { job in
            guard !job.isCancelled, job.policy == .explicit,
                  requests.contains(.init(jobId: job.id, requestedAt: job.requestedAt)) else { return nil }
            var interrupted = job
            interrupted.lastFailureCode = waitingForSystem
            return interrupted
        }
    }

    /// Automatic enqueueing must not turn the listener's explicit request into charging-only work.
    public static func automaticJob(_ job: AudioPreparationJob, committedChunks: Int) -> AudioPreparationJob {
        guard job.policy != .explicit else { return job }
        let openingBuffer = job.policy == .demandWindow
            && job.maximumChunkCount.map { committedChunks < $0 } == true
        guard !openingBuffer else { return job }
        var automatic = job
        automatic.policy = .whileCharging
        automatic.maximumChunkCount = nil
        return automatic
    }
}
