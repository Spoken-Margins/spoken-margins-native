/// The outcome of one background preparation pass.
public enum BackgroundPreparationWorkResult: Equatable, Sendable {
    case finished
    case continueNow
    case retryLater

    public var hasRemainingWork: Bool { self != .finished }
}

/// Scheduling rules only; the caller owns storage, tasks and device state.
public struct BackgroundPreparationPlanner {
    public struct Environment {
        /// True for either the serious or critical thermal state.
        public var thermalIsSerious: Bool
        public var lowPowerMode: Bool
        public var episodeTaskIsRunning: Bool

        public init(thermalIsSerious: Bool, lowPowerMode: Bool, episodeTaskIsRunning: Bool) {
            self.thermalIsSerious = thermalIsSerious
            self.lowPowerMode = lowPowerMode
            self.episodeTaskIsRunning = episodeTaskIsRunning
        }
    }

    private var prefersEpisodeMap = true

    public init() {}

    public static func eligibleEpisodeJobs(
        _ jobs: [EpisodeMapPreparationJob],
        episodePolicy: AutomaticEpisodeMapPreparationPolicy,
        hasLocalAudio: (String) -> Bool
    ) -> [EpisodeMapPreparationJob] {
        jobs.filter {
            !$0.isCancelled
                && $0.stage != .completed
                && ($0.policy == .explicit || episodePolicy == .whileCharging)
                && hasLocalAudio($0.itemId)
        }
        .sorted {
            if $0.policy != $1.policy { return $0.policy == .explicit }
            return $0.requestedAt < $1.requestedAt
        }
    }

    /// Nil selects an audio pass, including when no eligible episode can run.
    public func plan(
        hasAudioWork: Bool,
        episodeJobs: [EpisodeMapPreparationJob],
        environment: Environment
    ) -> EpisodeMapPreparationJob? {
        let shouldRunEpisode = !episodeJobs.isEmpty
            && (!hasAudioWork || prefersEpisodeMap)
        if shouldRunEpisode,
           !environment.episodeTaskIsRunning,
           !environment.thermalIsSerious,
           !environment.lowPowerMode,
           let job = episodeJobs.first {
            return job
        }
        return nil
    }

    public mutating func afterEpisodePass() {
        prefersEpisodeMap = false
    }

    /// Returns whether work remains, using the jobs observed before the audio pass.
    public mutating func afterAudioPass(audioHasMore: Bool, hadAudioWork: Bool, hadEpisodeJobs: Bool) -> Bool {
        if hadAudioWork { prefersEpisodeMap = true }
        if audioHasMore { return true }
        if hadEpisodeJobs {
            prefersEpisodeMap = true
            return true
        }
        return false
    }

    public static func result(
        hasRemainingWork: Bool,
        before: [String],
        after: @autoclosure () -> [String]
    ) -> BackgroundPreparationWorkResult {
        guard hasRemainingWork else { return .finished }
        return after() == before ? .retryLater : .continueNow
    }

    public static func progressToken(audioJobs: [AudioPreparationJob], episodeJobs: [EpisodeMapPreparationJob]) -> [String] {
        let audio = audioJobs
            .filter { !$0.isCancelled }
            .map { "audio:\($0.id):\($0.nextChunkIndex)" }
        let episode = episodeJobs
            .filter { !$0.isCancelled && $0.stage != .completed }
            .map { "episode:\($0.id):\($0.stage.rawValue):\($0.nextUnitIndex)" }
        return (audio + episode).sorted()
    }
}
