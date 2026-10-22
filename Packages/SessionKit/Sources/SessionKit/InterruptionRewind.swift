import Foundation

/// How far a podcast or recording steps back when it resumes after the system paused it (a call, Siri, another
/// app taking the audio), so the listener hears the end of the thought again. The longer they were away, the
/// further back (#1975). The Margin rejoin (`MarginRejoin`) has its own, fixed step.
enum InterruptionRewind {
    /// Under this a pause is a blip: iOS pauses and resumes within a second for a notification chime.
    static let blipSeconds: TimeInterval = 2
    static let shortPauseSeconds: TimeInterval = 30
    static let mediumPauseSeconds: TimeInterval = 5 * 60

    static let shortPauseStepBackMs = 3_000
    static let mediumPauseStepBackMs = 6_000
    static let longPauseStepBackMs = 10_000

    /// The step back for a pause that lasted `pausedForSeconds`. Never negative; an unreadable duration steps nowhere.
    static func rewindMs(pausedForSeconds: TimeInterval) -> Int {
        guard !pausedForSeconds.isNaN, pausedForSeconds >= blipSeconds else { return 0 }
        if pausedForSeconds <= shortPauseSeconds { return shortPauseStepBackMs }
        if pausedForSeconds <= mediumPauseSeconds { return mediumPauseStepBackMs }
        return longPauseStepBackMs
    }
}
