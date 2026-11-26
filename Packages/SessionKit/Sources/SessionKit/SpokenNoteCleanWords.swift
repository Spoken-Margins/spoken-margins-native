import Foundation

/// Where making a note's version with shorter pauses stands, as the control and Now show it (#4779).
public enum SpokenNoteCleanState: Equatable, Sendable {
    /// As recorded is chosen.
    case asRecorded
    /// Shorter pauses is chosen and the note hasn't been played since: its version is made (or found) when it plays.
    case untilPlayed
    /// Being made; `fraction` from 0 to 1. The note plays as recorded meanwhile.
    case making(fraction: Double)
    /// Made and playing: `recordedMs` long as recorded, `versionMs` long with shorter pauses.
    case ready(recordedMs: Int, versionMs: Int)
    /// No pause long enough to shorten: the note plays as recorded.
    case nothingToRemove
    /// Waiting while the phone is hot (thermal state serious or critical).
    case hot
    case failed(SpokenNoteCleanResult.Failure)

    /// What the job's saved result means for the control, for a note whose version is chosen.
    public static func from(result: SpokenNoteCleanResult, recordedMs: Int, versionMs: Int) -> SpokenNoteCleanState {
        switch result {
        case .made: return .ready(recordedMs: recordedMs, versionMs: versionMs)
        case .nothingToRemove: return .nothingToRemove
        case .failed(let failure): return .failed(failure)
        case .interrupted: return .making(fraction: 0)
        }
    }

    /// Whether the control offers Try again.
    public var offersTryAgain: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Every word the note's audio control and the line on Now say, in one table, so the note screen, Listening options
/// and Now say the same thing (#4779). PR 0 landed on branch C: the version shortens long pauses and keeps ums, so it
/// is called "Shorter pauses".
public enum SpokenNoteCleanWords {
    public static let controlLabel = "Note audio"

    public static func segment(_ version: SpokenNoteAudioVersion) -> String {
        switch version {
        case .asRecorded: return "As recorded"
        case .shorterPauses: return "Shorter pauses"
        }
    }

    public static let tryAgain = "Try again"

    /// The caption under the control: one line, and a second for a version that is ready.
    public static func caption(_ state: SpokenNoteCleanState) -> (line: String, second: String?) {
        switch state {
        case .asRecorded:
            return ("Plays your note exactly as you recorded it.", nil)
        case .untilPlayed:
            return ("Long pauses are shortened when the note plays. Your recording stays as it is.", nil)
        case .making(let fraction):
            return ("Shortening long pauses… \(percent(fraction))%. Playing as recorded until it's ready.", nil)
        case .ready(let recordedMs, let versionMs):
            return (
                "Long pauses are shortened. Your recording stays as it is.",
                "\(length(recordedMs)) as recorded, \(length(versionMs)) with shorter pauses."
            )
        case .nothingToRemove:
            return ("No long pauses to shorten in this note, so it plays as recorded.", nil)
        case .hot:
            return ("Paused while your iPhone cools down. Playing as recorded.", nil)
        case .failed(.noSpace):
            return ("There isn't enough free space on this iPhone to make the version with shorter pauses. It plays as recorded.", nil)
        case .failed(.other):
            return ("Couldn't shorten the pauses in this note, so it plays as recorded. Your recording is unchanged.", nil)
        }
    }

    /// The line on Now, under the title. Nil when there is none: As recorded is chosen, or there was nothing to shorten.
    public static func nowLine(_ state: SpokenNoteCleanState) -> String? {
        switch state {
        case .asRecorded, .untilPlayed, .nothingToRemove:
            return nil
        case .making(let fraction):
            return "Shortening pauses… \(percent(fraction))%"
        case .ready(let recordedMs, let versionMs):
            return "Shorter pauses · \(shorter(savedMs: recordedMs - versionMs))"
        case .hot, .failed:
            return "As recorded for now"
        }
    }

    // MARK: Number rules

    /// In steps of 5, rounded down.
    public static func percent(_ fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        return Int((clamped * 100).rounded(.down)) / 5 * 5
    }

    /// To the nearest minute; under a minute, in seconds ("45 s").
    public static func length(_ ms: Int) -> String {
        let seconds = Int((Double(max(0, ms)) / 1_000).rounded())
        guard seconds >= 60 else { return "\(seconds) s" }
        return "\(Int((Double(seconds) / 60).rounded())) min"
    }

    /// The time saved, to the nearest minute; under 60 s, "under a minute shorter".
    public static func shorter(savedMs: Int) -> String {
        guard savedMs >= 60_000 else { return "under a minute shorter" }
        return "\(Int((Double(savedMs) / 60_000).rounded())) min shorter"
    }
}
