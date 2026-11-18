import Foundation

/// How a run to summarise an article's or PDF's scenes began.
public enum TextSceneSummaryStart: Equatable, Sendable {
    case started
    case alreadyRunning
    /// Another item's summaries are being written; one run at a time.
    case busyWithAnotherItem
    /// The on-device model can't be used, so the item keeps its rule-based chapters. Carries the model's own reason.
    case modelUnavailable(String)

    /// A plain sentence to add after the chapters are made.
    public var note: String {
        switch self {
        case .started: "Writing scene summaries on this device."
        case .alreadyRunning: "Scene summaries are still being written."
        case .busyWithAnotherItem: "Scene summaries for something else are still being written, so this one has chapters only."
        case .modelUnavailable(let reason): "Scene summaries need the on-device model, so the chapters have no summaries. \(reason)."
        }
    }
}

/// How a run to summarise an article's or PDF's scenes ended.
public enum TextSceneSummaryOutcome: Equatable, Sendable {
    case summarised(scenes: Int, total: Int)
    /// The text has nothing the model can summarise (too short, or only headings).
    case nothingToSummarise
    /// The model ran but none of its summaries passed the grounding check.
    case noSummaryAccepted
    /// The listener already has another map for this text, which stays.
    case keptOtherMap
    /// The phone got warm or went into Low Power Mode, so the run stopped with the summaries so far saved (#3461).
    case paused(EpisodeMapRunStop, written: Int, total: Int)
    /// Every scene is decided and saved, but the phone got warm while their audio was being made. Skim makes the audio
    /// later, so there is nothing to continue.
    case audioPaused(EpisodeMapRunStop)
    /// The on-device model threw instead of answering (busy, or not ready). The summaries so far are saved, and it says
    /// nothing about the scenes left, so they stay waiting.
    case modelStopped(written: Int, total: Int)
    case cancelled
    case failed(String)

    /// True when the background pass should not pick this item again: the run ended for good, or failed (a run that
    /// fails every time must not keep the charging pass from the items behind it).
    public var settlesBackgroundRun: Bool {
        switch self {
        case .paused, .audioPaused, .modelStopped, .cancelled: false
        case .summarised, .nothingToSummarise, .noSummaryAccepted, .keptOtherMap, .failed: true
        }
    }

    /// True when running again later could add summaries, so a background pass leaves the item for another time.
    public var canBeContinued: Bool {
        switch self {
        case .paused, .modelStopped, .cancelled, .failed: true
        case .summarised, .audioPaused, .nothingToSummarise, .noSummaryAccepted, .keptOtherMap: false
        }
    }

    public var message: String {
        switch self {
        case .summarised(let scenes, let total): "Scene summaries are ready (\(scenes) of \(total) scenes). Skim can read them."
        case .nothingToSummarise: "This text is too short to summarise. The chapters stay as they are."
        case .noSummaryAccepted: "The on-device model's summaries didn't pass the check, so the chapters stay without summaries."
        case .keptOtherMap: "This already has a Listening Map, so it was not replaced."
        case .paused(let stop, let written, let total):
            "\(EpisodeMapRunGuard.pausedStatus(stop)). \(written) of \(total) scene summaries are saved. Tap Continue Scene Summaries to pick up there."
        case .audioPaused(let stop):
            "\(EpisodeMapRunGuard.pausedStatus(stop)). The scene summaries are saved, and Skim makes their audio later."
        case .modelStopped(let written, let total):
            "The on-device model stopped answering. \(written) of \(total) scene summaries are saved. Tap Continue Scene Summaries to try again."
        case .cancelled: "Stopped writing scene summaries. The ones already written are kept."
        case .failed(let reason): "Couldn't write scene summaries. \(reason)"
        }
    }

    public var diagnostic: String {
        switch self {
        case .summarised(let scenes, let total): "summarised \(scenes) of \(total)"
        case .nothingToSummarise: "nothing_to_summarise"
        case .noSummaryAccepted: "no_summary_accepted"
        case .keptOtherMap: "kept_other_map"
        case .paused(let stop, let written, let total): "\(stop.code) \(written) of \(total)"
        case .audioPaused(let stop): "audio \(stop.code)"
        case .modelStopped(let written, let total): "model_stopped \(written) of \(total)"
        case .cancelled: "cancelled"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}
