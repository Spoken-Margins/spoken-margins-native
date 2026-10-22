import Foundation

/// What one Skim press can do from where the listener is (#2185).
///
/// Skim used to be offered only when a scene's summary audio was already saved and verified. A mapped episode whose
/// summaries were never rendered, or were rendered in a voice the listener has since changed, had no Skim at all: the
/// slot became Next chapter without a word, and a Skim from the Live Activity did nothing. A scene that has summary
/// text now counts as skimmable: the press prepares the summary in the current voice, then plays it.
public enum SkimReadiness: Equatable, Sendable {
    /// The summary audio is saved and verified: play it now.
    case ready
    /// The scene has a summary but no audio yet: prepare it in the current voice, then play it.
    case needsSummaryAudio
    /// Skim can't run from here, and this is why.
    case unavailable(SkimUnavailableReason)

    /// Whether the Skim control can be pressed.
    public var isPressable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    public var unavailableReason: SkimUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// - Parameters:
    ///   - hasMap: the item has a resolved Listening Map and the proposal it places.
    ///   - hasPlan: `SceneStarts.skimPlan` found a summary scene and a destination from here.
    ///   - hasReadyAudio: a verified summary audio file for that scene, in the current voice, is on the phone.
    ///   - suppliesItsOwnVoice: the scene names a recorded summary from a package (`summaryAssetId`), which is never
    ///     replaced with synthesized speech.
    public static func of(hasMap: Bool, hasPlan: Bool, hasReadyAudio: Bool, suppliesItsOwnVoice: Bool) -> SkimReadiness {
        guard hasMap else { return .unavailable(.noMap) }
        guard hasPlan else { return .unavailable(.noSceneSummary) }
        if hasReadyAudio { return .ready }
        return suppliesItsOwnVoice ? .unavailable(.suppliedSummaryMissing) : .needsSummaryAudio
    }
}

/// Why a Skim press could not play a summary. The raw value is the `reason` field in Diagnostics.
public enum SkimUnavailableReason: String, Equatable, Sendable {
    /// Not a media item, a recording in progress, or no store.
    case noSource = "no_source"
    /// The item has no Listening Map.
    case noMap = "no_map"
    /// No placed scene with a summary from here: before the first scene, past the end, or an unplaced next scene.
    case noSceneSummary = "no_scene_summary"
    /// The package's recorded summary for this scene is missing.
    case suppliedSummaryMissing = "supplied_summary_missing"
    /// Preparing the summary in the current voice produced no audio or threw.
    case preparationFailed = "preparation_failed"
    /// The summary was prepared, but by then the listener had moved on (another item, or a Skim already playing).
    case movedOn = "moved_on"

    /// What the listener is told, in place of a Skim that does nothing.
    public var message: String {
        switch self {
        case .noSource: return "Skim isn't available while recording or outside an episode."
        case .noMap: return "Skim needs a Listening Map for this episode."
        case .noSceneSummary: return "There's no scene summary to skim to from here."
        case .suppliedSummaryMissing: return "This scene's recorded summary is missing. Reimport the package to restore it."
        case .preparationFailed: return "The scene summary couldn't be prepared, so Skim didn't move."
        case .movedOn: return "Skim stopped because playback moved on while the summary was being prepared."
        }
    }
}

/// One Skim press's outcome, logged once per press as `skim.press` (#2185). The raw value is the `outcome` field.
public enum SkimPressOutcome: String, Equatable, Sendable {
    /// The summary started playing.
    case playedSummary = "played_summary"
    /// No audio yet: preparing it in the current voice. A second line follows with how that ended.
    case preparingSummary = "preparing_summary"
    /// The summary could not be prepared or played.
    case noAudio = "no_audio"
    /// Nothing to skim to from here.
    case noPlan = "no_plan"
    /// The Skim slot held Next chapter, and the press made a plain chapter jump.
    case fellBackToChapter = "fell_back_to_chapter"
    /// A second press while a summary played ended it at its destination.
    case completedBridge = "completed_bridge"
    /// A press while a summary was still being prepared; it is ignored.
    case alreadyPreparing = "already_preparing"

    /// The fields of the `skim.press` Diagnostics event.
    public func diagnosticFields(direction: SkimDirection, reason: String? = nil) -> [String: String] {
        var fields = ["outcome": rawValue, "direction": direction.rawValue]
        if let reason { fields["reason"] = reason }
        return fields
    }
}
