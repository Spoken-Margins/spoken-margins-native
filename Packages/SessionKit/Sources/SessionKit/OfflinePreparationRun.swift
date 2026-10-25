import Foundation

/// An explicit Make available offline run that has to outlast the screen (#905).
///
/// The listener taps Make available offline on a long article and puts the phone down. These rules
/// decide when iOS is asked to keep the app running, what its progress banner says, and how a heat
/// pause ends. They are pure so host tests pin them; the app only carries them out.
public enum OfflinePreparationRun {
    /// One listener request: tapping Make available offline again on the same article is a new request.
    public struct RequestKey: Hashable, Sendable {
        public var jobId: String
        public var requestedAt: Date

        public init(jobId: String, requestedAt: Date) {
            self.jobId = jobId
            self.requestedAt = requestedAt
        }
    }

    /// One queue entry, as far as a run cares.
    public struct Job: Equatable, Sendable {
        public var id: String
        public var manifestId: String
        public var requestedAt: Date
        public var policy: PreparationJobPolicy
        public var state: PreparedAudioState
        public var completedChunks: Int
        public var plannedChunks: Int

        public init(
            id: String = "",
            manifestId: String = "",
            requestedAt: Date = Date(timeIntervalSince1970: 0),
            policy: PreparationJobPolicy,
            state: PreparedAudioState,
            completedChunks: Int,
            plannedChunks: Int
        ) {
            self.id = id
            self.manifestId = manifestId
            self.requestedAt = requestedAt
            self.policy = policy
            self.state = state
            self.completedChunks = completedChunks
            self.plannedChunks = plannedChunks
        }

        var requestKey: RequestKey { RequestKey(jobId: id, requestedAt: requestedAt) }
        var isOpenExplicitRequest: Bool { policy == .explicit && OfflinePreparationRun.isOpen(state) }
    }

    public struct Progress: Equatable, Sendable {
        public var completedChunks: Int
        public var totalChunks: Int

        public init(completedChunks: Int, totalChunks: Int) {
            self.completedChunks = completedChunks
            self.totalChunks = totalChunks
        }

        public var remainingChunks: Int { max(0, totalChunks - completedChunks) }
    }

    /// What the listener asked for and hasn't got yet: explicit requests that still have chunks to
    /// make. Opening buffers and While Charging work are not the listener's to wait on, so they
    /// never count. A job that failed or was stopped waits for the listener, not for the run.
    ///
    /// `declined` holds requests iOS or the listener already ended the background time for; they
    /// stay in the queue but don't count here, so the app doesn't ask again for them.
    public static func explicitProgress(_ jobs: [Job], excluding declined: Set<RequestKey> = []) -> Progress {
        let open = jobs.filter { $0.isOpenExplicitRequest && !declined.contains($0.requestKey) }
        let total = open.reduce(0) { $0 + max(0, $1.plannedChunks) }
        let completed = open.reduce(0) { $0 + min(max(0, $1.completedChunks), max(0, $1.plannedChunks)) }
        return Progress(completedChunks: completed, totalChunks: total)
    }

    /// A running system banner retains verified completions, even after their queue rows disappear.
    /// A rendered last chunk still needs final assembly and verification before reporting 100%.
    public static func continuedProgress(_ jobs: [Job]) -> Progress {
        let explicit = jobs.filter { $0.policy == .explicit }
        let total = explicit.reduce(0) { $0 + max(0, $1.plannedChunks) }
        let completed = explicit.reduce(0) { count, job in
            let limit = max(0, job.plannedChunks - (job.state == .readyOffline ? 0 : 1))
            return count + min(max(0, job.completedChunks), limit)
        }
        return Progress(completedChunks: completed, totalChunks: total)
    }

    public static func continuedRunFinished(_ jobs: [Job]) -> Bool {
        let explicit = jobs.filter { $0.policy == .explicit }
        return !explicit.isEmpty && explicit.allSatisfy { $0.state == .readyOffline }
    }

    /// Disappearance alone can mean Skip, Clear Queue, failure or completion. Only a verified
    /// artifact proves completion. The app supplies the actual manifest from its store.
    public static func resolvingRemovedJob(_ job: Job, manifest: PreparedAudioManifest?) -> Job {
        var resolved = job
        if let manifest, manifest.state == .readyOffline, manifest.artifact != nil {
            resolved.state = .readyOffline
            resolved.completedChunks = max(0, job.plannedChunks)
        } else {
            resolved.state = .stopped
        }
        return resolved
    }

    /// The requests that are still open, to remember as declined when the background time ends.
    public static func openExplicitRequests(_ jobs: [Job]) -> Set<RequestKey> {
        Set(jobs.filter(\.isOpenExplicitRequest).map(\.requestKey))
    }

    fileprivate static func isOpen(_ state: PreparedAudioState) -> Bool {
        switch state {
        case .notPrepared, .preparing, .pausedForThermal: true
        case .readyOffline, .needsRepreparation, .stopped, .failed: false
        }
    }

    // MARK: Asking iOS to keep going

    /// A run shorter than this finishes while the listener is still looking at the screen, so it
    /// doesn't get a system progress banner of its own.
    public static let minimumChunksForContinuedProcessing = 5

    /// iOS accepts continued processing only for work the listener just started in the app, so the
    /// request is made while the app is on screen. One request covers the whole queue.
    ///
    /// `preparationAllowed` is false while playback or a restored speech session holds the Library
    /// back (#2694): a card then would report a run that cannot start, and end as failed.
    public static func shouldRequestContinuedProcessing(
        _ progress: Progress,
        alreadyRequested: Bool,
        appIsActive: Bool,
        preparationAllowed: Bool
    ) -> Bool {
        preparationAllowed && appIsActive && !alreadyRequested
            && progress.remainingChunks >= minimumChunksForContinuedProcessing
    }

    // MARK: The system progress banner

    public enum Phase: Equatable, Sendable {
        case preparing
        case coolingDown
    }

    public static let continuedTitle = "Preparing audio for offline listening"

    public static func continuedSubtitle(_ progress: Progress, phase: Phase) -> String {
        guard progress.totalChunks > 0 else { return "Finishing" }
        let count = "\(progress.completedChunks) of \(progress.totalChunks)"
        switch phase {
        case .preparing: return count
        case .coolingDown: return "Paused while the phone cools · \(count)"
        }
    }

    // MARK: Waiting out a heat or memory pause

    /// Heat can hold a run for a long time. After this the run stops waiting and the queued jobs
    /// carry on the next time the listener opens the app.
    public static let maximumHeatWaitSeconds = 30 * 60

    /// A memory warning blocks rendering for about a minute, so a backoff that is still there after
    /// this long has been renewed again and again. The run stops waiting and the queued jobs carry
    /// on the next time the listener opens the app.
    public static let maximumMemoryWaitSeconds = 10 * 60

    /// A memory backoff ends on its own within about a minute, so it is rechecked at the quick pace.
    public static let memoryRecheckSeconds = 15

    public enum HeatWaitStop: String, Equatable, Sendable {
        /// Nothing the foreground loop prepares is queued any more.
        case noWorkWaiting = "no_work_waiting"
        /// The pass stopped for a reason other than heat or a memory backoff, so waiting would not help.
        case notHeat = "not_heat"
        case waitedTooLong = "waited_too_long"
    }

    public enum HeatWaitStep: Equatable, Sendable {
        case wait(seconds: Int)
        /// The phone cooled, or the memory backoff ended, while the run waited: run the pass again.
        case resume
        case stop(HeatWaitStop)
    }

    /// What a run does after a pass rendered nothing. A hot phone is rechecked, quickly at first and
    /// then every minute, because the heat state changes slowly. Serious and critical heat hold the
    /// run; fair and nominal let it go on, the same line `PreparationChunkGate` draws.
    ///
    /// Before this a heat pause ended the loop, and nothing started it again once the phone cooled.
    public static func heatWaitStep(
        thermal: SpeechThermalLevel,
        waitedSeconds: Int,
        foregroundWorkWaiting: Bool
    ) -> HeatWaitStep {
        pauseWaitStep(
            thermal: thermal,
            memoryBackoffActive: false,
            waitedSeconds: waitedSeconds,
            foregroundWorkWaiting: foregroundWorkWaiting
        )
    }

    /// `heatWaitStep` for the two pauses the loop can wait out: heat, and the backoff a memory
    /// warning starts. Either one holds the run; once neither does and the run has waited, it goes
    /// on. A backoff that keeps being renewed ends the wait after `maximumMemoryWaitSeconds`, heat
    /// after `maximumHeatWaitSeconds`.
    ///
    /// Before this a memory warning ended the loop for good: the pass after it rendered nothing
    /// because of the backoff, and nothing started the run again when the backoff was over (#1107).
    public static func pauseWaitStep(
        thermal: SpeechThermalLevel,
        memoryBackoffActive: Bool,
        waitedSeconds: Int,
        foregroundWorkWaiting: Bool
    ) -> HeatWaitStep {
        guard foregroundWorkWaiting else { return .stop(.noWorkWaiting) }
        let tooWarm = PreparationChunkGate.isTooWarm(thermal)
        guard tooWarm || memoryBackoffActive else {
            return waitedSeconds > 0 ? .resume : .stop(.notHeat)
        }
        let limit = tooWarm ? maximumHeatWaitSeconds : maximumMemoryWaitSeconds
        guard waitedSeconds < limit else { return .stop(.waitedTooLong) }
        return .wait(seconds: tooWarm ? heatRecheckSeconds(afterWaiting: waitedSeconds) : memoryRecheckSeconds)
    }

    public static func heatRecheckSeconds(afterWaiting waitedSeconds: Int) -> Int {
        switch waitedSeconds {
        case ..<60: 15
        case ..<300: 30
        default: 60
        }
    }
}
