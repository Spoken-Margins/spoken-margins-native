import Foundation

/// Pure sleep-timer decisions; the caller owns ticking and playback effects.
public enum SleepTimerPolicy {
    public static func isActive(_ sleepTimerState: SleepTimerState) -> Bool {
        if case .inactive = sleepTimerState { return false }
        return true
    }

    public static func description(state sleepTimerState: SleepTimerState, remainingSeconds sleepTimerRemainingSeconds: Int?) -> String {
        switch sleepTimerState {
        case .inactive: return "Sleep Timer"
        case .armed(let mode, _, _):
            if mode == .endOfChapter { return "End of Chapter" }
            guard let seconds = sleepTimerRemainingSeconds else { return "Sleep Timer" }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .expiryDeferred: return "Pauses after recording"
        }
    }

    public static func arm(_ mode: SleepTimerMode, now: Date, chapters: [MediaTimelineChapter], currentMediaTimeMs: Int?) -> SleepTimerState? {
        let deadline: Date?
        let chapterId: String?
        switch mode {
        case .minutes15: deadline = now.addingTimeInterval(15 * 60); chapterId = nil
        case .minutes30: deadline = now.addingTimeInterval(30 * 60); chapterId = nil
        case .minutes45: deadline = now.addingTimeInterval(45 * 60); chapterId = nil
        case .minutes60: deadline = now.addingTimeInterval(60 * 60); chapterId = nil
        case .endOfChapter:
            guard let target = endOfChapterTarget(chapters: chapters, currentMediaTimeMs: currentMediaTimeMs) else { return nil }
            deadline = nil
            chapterId = target.chapterId
        }
        return .armed(mode: mode, deadline: deadline, chapterId: chapterId)
    }

    public static func extend(_ sleepTimerState: SleepTimerState, now: Date) -> SleepTimerState {
        let deadline: Date
        switch sleepTimerState {
        case .armed(_, let current?, _): deadline = max(current, now).addingTimeInterval(15 * 60)
        case .expiryDeferred: deadline = now.addingTimeInterval(15 * 60)
        case .inactive, .armed(_, nil, _): deadline = now.addingTimeInterval(15 * 60)
        }
        return .armed(mode: .minutes15, deadline: deadline, chapterId: nil)
    }

    public static func reconcile(state sleepTimerState: inout SleepTimerState, remainingSeconds sleepTimerRemainingSeconds: inout Int?, now: Date, isRecording: Bool, currentMediaTimeMs: Int?, chapters: [MediaTimelineChapter]) -> SleepTimerMode? {
        switch sleepTimerState {
        case .inactive:
            sleepTimerRemainingSeconds = nil
        case .expiryDeferred(let mode):
            sleepTimerRemainingSeconds = 0
            if !isRecording { return mode }
        case .armed(let mode, let deadline, let chapterId):
            if let deadline {
                let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
                sleepTimerRemainingSeconds = remaining
                if remaining == 0 { return requestSleepTimerExpiry(mode: mode, isRecording: isRecording, state: &sleepTimerState) }
            } else if mode == .endOfChapter,
                      let target = endOfChapterTarget(chapters: chapters, currentMediaTimeMs: currentMediaTimeMs, chapterId: chapterId),
                      (currentMediaTimeMs ?? 0) >= target.endMs {
                return requestSleepTimerExpiry(mode: mode, isRecording: isRecording, state: &sleepTimerState)
            }
        }
        return nil
    }

    private static func requestSleepTimerExpiry(mode: SleepTimerMode, isRecording: Bool, state sleepTimerState: inout SleepTimerState) -> SleepTimerMode? {
        if isRecording {
            sleepTimerState = .expiryDeferred(mode: mode)
        } else {
            return mode
        }
        return nil
    }

    public static func expiryConfirmation(mode: SleepTimerMode) -> String {
        mode == .endOfChapter ? "Paused at the end of the chapter." : "Sleep timer paused playback."
    }

    public static func endOfChapterTarget(chapters: [MediaTimelineChapter], currentMediaTimeMs: Int?, chapterId: String? = nil) -> (chapterId: String, endMs: Int)? {
        let chapters = chapters.sorted { $0.startMs < $1.startMs }
        guard chapters.count > 1 else { return nil }
        let currentMs = currentMediaTimeMs ?? 0
        let index: Int
        if let chapterId, let exact = chapters.firstIndex(where: { $0.id == chapterId }) { index = exact }
        else { index = chapters.lastIndex(where: { $0.startMs <= currentMs }) ?? 0 }
        guard chapters.indices.contains(index + 1) else { return nil }
        return (chapters[index].id, chapters[index + 1].startMs)
    }

}
