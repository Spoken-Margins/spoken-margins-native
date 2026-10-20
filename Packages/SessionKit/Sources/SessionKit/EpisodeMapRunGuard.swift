import Foundation

/// What asked for an episode map run. Diagnostics name it, so a map the listener didn't expect can be traced
/// to a tap, a finished download or the background pass.
public enum EpisodeMapPreparationTrigger: String, Codable, Equatable, Sendable {
    /// The listener tapped to make the map.
    case listenerRequest = "listener_request"
    /// A map the listener asked for was waiting on its download, which just finished.
    case downloadFinished = "download_finished"
    /// The background preparation pass picked up a saved job.
    case backgroundPass = "background_pass"
}

/// Why a run stopped before finishing.
public enum EpisodeMapRunStop: Equatable, Sendable {
    /// The phone reached serious or critical heat. The job waits for a cooler pass.
    case heat(SpeechThermalLevel)
    /// Low Power Mode came on during a job the listener didn't ask for.
    case lowPowerMode
    /// iOS ended the background time the pass was running in.
    case backgroundTimeExpired
    /// The listener cancelled the map, or the item went away.
    case cancelled

    /// Saved on the job as `lastFailureCode`. Older builds read it as an opaque string.
    public var code: String {
        switch self {
        case .heat(let level): "paused:heat_\(level.rawValue)"
        case .lowPowerMode: "paused:low_power_mode"
        case .backgroundTimeExpired: "paused:background_time_expired"
        case .cancelled: "cancelled"
        }
    }

    /// A pause keeps the job for a later pass; only a cancel drops it.
    public var keepsJob: Bool { self != .cancelled }
}

/// The rules a running episode map job checks while it works (found on the owner's phone on 2026-10-18:
/// a 60-minute map kept transcribing for 21 minutes at serious heat, because heat was checked only before it
/// started). Also the wording of its diagnostics, so each event says what started it, when, and why it stopped.
public enum EpisodeMapRunGuard {
    /// Saved on the job while a run is in flight. A later request that finds it knows the previous run ended
    /// without recording why (the app was suspended or killed).
    public static let runningCode = "running"

    /// Nil lets the run continue. Heat stops any run, as it does Library audio preparation; Low Power Mode
    /// stops only work the listener didn't ask for (`PreparationChunkGate.holdsForLowPowerMode`).
    public static func yieldReason(
        conditions: SpeechEngineConditions,
        policy: PreparationJobPolicy
    ) -> EpisodeMapRunStop? {
        if PreparationChunkGate.isTooWarm(conditions.thermal) { return .heat(conditions.thermal) }
        if PreparationChunkGate.holdsForLowPowerMode(policy, isLowPowerModeEnabled: conditions.isLowPowerModeEnabled) {
            return .lowPowerMode
        }
        return nil
    }

    /// Applies a stop to the job: a pause keeps it for a later pass, a cancel drops it. Returns the diagnostic.
    public static func stop(
        _ stop: EpisodeMapRunStop,
        job: inout EpisodeMapPreparationJob,
        at date: Date
    ) -> String {
        job.isCancelled = !stop.keepsJob
        job.lastFailureCode = stop.code
        return "\(stop.code):stage=\(job.stage.rawValue):at=\(timestamp(date))"
    }

    public static func startedDiagnostic(
        trigger: EpisodeMapPreparationTrigger,
        job: EpisodeMapPreparationJob,
        thermal: SpeechThermalLevel,
        at date: Date
    ) -> String {
        "started:trigger=\(trigger.rawValue):policy=\(job.policy.rawValue):stage=\(job.stage.rawValue)"
            + ":unit=\(job.nextUnitIndex):heat=\(thermal.rawValue):at=\(timestamp(date))"
    }

    public static func waitingDiagnostic(trigger: EpisodeMapPreparationTrigger, at date: Date) -> String {
        "waiting_for_local_audio:trigger=\(trigger.rawValue):at=\(timestamp(date))"
    }

    public static func checkpointDiagnostic(landmark: Int, at date: Date) -> String {
        "checkpoint:fingerprint_landmark=\(landmark):at=\(timestamp(date))"
    }

    public static func failedDiagnostic(_ description: String, stage: EpisodeMapPreparationStage, at date: Date) -> String {
        "failed:\(description):stage=\(stage.rawValue):at=\(timestamp(date))"
    }

    /// The saved job of a run that ended without recording why, or nil.
    public static func interruptedRunDiagnostic(previous job: EpisodeMapPreparationJob?) -> String? {
        guard let job, !job.isCancelled, job.lastFailureCode == runningCode else { return nil }
        return "previous_run_ended_unrecorded:stage=\(job.stage.rawValue):unit=\(job.nextUnitIndex)"
    }

    /// What the item screen shows while the job waits.
    public static func pausedStatus(_ stop: EpisodeMapRunStop) -> String {
        switch stop {
        case .heat: "Paused while the phone is warm"
        case .lowPowerMode: "Paused for Low Power Mode"
        case .backgroundTimeExpired: "Paused until the next background pass"
        case .cancelled: "Cancelled"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
