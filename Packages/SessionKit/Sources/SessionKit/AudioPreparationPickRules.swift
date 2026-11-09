import Foundation

/// The one place that says which queued preparation jobs a pass can pick up right now. The pass chooses its job
/// from `candidates`, its "is there more" question reads `hasWork`, and the run summary's drain reads `isDrained`,
/// so a filter added here reaches all three. Four audit findings on #3816 were each one filter the drain had
/// copied from the pass and left out: stopped jobs, opening buffers, another engine's jobs, Low Power Mode.
public struct AudioPreparationPickRules {
    /// Keeps the jobs filed under the chosen voice's engine; another engine's jobs wait for that voice.
    public var ownJobs: ([AudioPreparationJob]) -> [AudioPreparationJob]
    public var thermal: SpeechThermalLevel
    public var isLowPowerModeEnabled: Bool
    public var automaticPolicy: AutomaticAudioPreparationPolicy

    public init(
        ownJobs: @escaping ([AudioPreparationJob]) -> [AudioPreparationJob],
        thermal: SpeechThermalLevel,
        isLowPowerModeEnabled: Bool,
        automaticPolicy: AutomaticAudioPreparationPolicy
    ) {
        self.ownJobs = ownJobs
        self.thermal = thermal
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.automaticPolicy = automaticPolicy
    }

    /// The jobs `caller`'s pass chooses among: this voice's own jobs, less those Low Power Mode sets aside, and for
    /// the background task less the automatic jobs that preparation setting doesn't allow.
    public func candidates(_ jobs: [AudioPreparationJob], for caller: LibraryAudioPreparationCaller) -> [AudioPreparationJob] {
        let kept = ownJobs(jobs).filter {
            !PreparationChunkGate.setsAsideForLowPowerMode($0.policy, thermal: thermal, isLowPowerModeEnabled: isLowPowerModeEnabled)
        }
        switch caller {
        case .foreground: return kept
        case .background: return OfflinePreparationRecovery.backgroundJobs(kept, automaticPolicy: automaticPolicy)
        }
    }

    /// What `caller`'s pass would take: a candidate that is neither stopped nor outside its turn.
    public func pickable(_ jobs: [AudioPreparationJob], for caller: LibraryAudioPreparationCaller) -> [AudioPreparationJob] {
        LibraryAudioPreparationTurns.eligible(candidates(jobs, for: caller), for: caller)
    }

    public func hasWork(_ jobs: [AudioPreparationJob], for caller: LibraryAudioPreparationCaller) -> Bool {
        !pickable(jobs, for: caller).isEmpty
    }

    /// No job is left that either pass could pick up. A stopped job, another engine's job and one Low Power Mode holds
    /// stay in the table, but nothing renders them now.
    public func isDrained(_ jobs: [AudioPreparationJob]) -> Bool {
        !hasWork(jobs, for: .foreground) && !hasWork(jobs, for: .background)
    }
}
