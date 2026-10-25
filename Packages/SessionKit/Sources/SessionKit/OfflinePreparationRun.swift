import Foundation

/// How a Make available offline run waits out a heat pause or a memory backoff (#905, #1107).
///
/// These rules are pure so host tests pin them; the app only carries them out.
public enum OfflinePreparationRun {
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
