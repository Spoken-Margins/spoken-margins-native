import Foundation

/// Where a running sleep timer is in its last minute (#1979): a listener falling asleep gets a quiet cue, then a
/// fade, instead of a cut mid-sentence.
public enum SleepTimerPhase: Equatable, Sendable {
    /// No timer is armed.
    case inactive
    /// More than `SleepTimerPolicy.warningSeconds` left, or no way to tell how long is left.
    case running
    /// Under a minute left; the listener can still extend. `secondsLeft` is rounded up.
    case warning(secondsLeft: Int)
    /// The last `SleepTimerPolicy.fadeSeconds`: playback runs at `volumeFactor` (1 down to 0) of its usual volume.
    case fading(volumeFactor: Double)
    /// Time is up (or waiting for a recording to finish).
    case ended
}

extension SleepTimerPolicy {
    /// Seconds before the end that the warning cue plays.
    public static let warningSeconds = 60
    /// Seconds before the end over which volume falls to nothing.
    public static let fadeSeconds = 10

    /// The phase at `now`. A timer by minutes counts down to its deadline. "End of chapter" counts down the media
    /// time left in the chapter, so it also warns and fades; it reads `running` when the chapter can't be found.
    public static func phase(
        state: SleepTimerState, now: Date, currentMediaTimeMs: Int?, chapters: [MediaTimelineChapter]
    ) -> SleepTimerPhase {
        switch state {
        case .inactive:
            return .inactive
        case .expiryDeferred:
            return .ended
        case .armed(_, let deadline?, _):
            return phase(secondsLeft: deadline.timeIntervalSince(now))
        case .armed(_, nil, let chapterId):
            guard let target = endOfChapterTarget(chapters: chapters, currentMediaTimeMs: currentMediaTimeMs, chapterId: chapterId) else {
                return .running
            }
            return phase(secondsLeft: Double(target.endMs - (currentMediaTimeMs ?? 0)) / 1_000)
        }
    }

    static func phase(secondsLeft: Double) -> SleepTimerPhase {
        guard secondsLeft > 0 else { return .ended }
        if secondsLeft <= Double(fadeSeconds) { return .fading(volumeFactor: secondsLeft / Double(fadeSeconds)) }
        if secondsLeft <= Double(warningSeconds) { return .warning(secondsLeft: Int(secondsLeft.rounded(.up))) }
        return .running
    }
}

/// Turns the phase seen on each tick into what the app should do once: play the cue the first time the warning
/// starts, set the fade volume, and put the volume back when the timer is extended or cancelled.
public struct SleepTimerFadeTracker: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case playWarningCue
        /// Multiply the listener's usual playback volume by this.
        case setVolumeFactor(Double)
        /// Back to the listener's usual playback volume.
        case restoreVolume
    }

    private var warned = false
    private var faded = false

    public init() {}

    /// True while the volume is below its usual level, so a ticker can run faster for a smooth fade.
    public var isFading: Bool { faded }

    public mutating func apply(_ phase: SleepTimerPhase) -> [Effect] {
        switch phase {
        case .inactive, .running:
            warned = false
            return restoreIfFaded()
        case .warning:
            let restore = restoreIfFaded()
            guard !warned else { return restore }
            warned = true
            return restore + [.playWarningCue]
        case .fading(let factor):
            // A tick that first sees the fade (a long gap between ticks) skips the cue: it would come with the fade.
            warned = true
            faded = true
            return [.setVolumeFactor(max(0, min(1, factor)))]
        case .ended:
            return []
        }
    }

    /// The timer was cancelled or has ended and playback has stopped: forget the fade, restoring volume if needed.
    public mutating func reset() -> [Effect] {
        warned = false
        return restoreIfFaded()
    }

    private mutating func restoreIfFaded() -> [Effect] {
        guard faded else { return [] }
        faded = false
        return [.restoreVolume]
    }
}
