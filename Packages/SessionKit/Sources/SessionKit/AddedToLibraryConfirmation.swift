import Foundation

/// #784: what the listener reads after adding something to the Library, and whether it offers Play now.
///
/// Imports never replace what's playing. So Play now appears only when Now Playing is empty, and even
/// then nothing starts until the listener taps it; share handoffs never autoplay.
public struct AddedToLibraryConfirmation: Equatable, Sendable {
    public let message: String
    public let offersPlayNow: Bool

    public init(title: String, nowPlayingIsEmpty: Bool) {
        if nowPlayingIsEmpty {
            message = "Added \(title) to Library."
            offersPlayNow = true
        } else {
            message = "Added \(title) to Library without changing Now Playing."
            offersPlayNow = false
        }
    }

    /// #828: several Safari shares imported together get one message and no Play now: the listener
    /// picks what to play from the Library.
    public static func message(addedCount count: Int, nowPlayingIsEmpty: Bool) -> String {
        let added = "Added \(count) items to Library"
        return nowPlayingIsEmpty ? "\(added)." : "\(added) without changing Now Playing."
    }

    /// VoiceOver names the item with the action.
    public static func playNowAccessibilityLabel(title: String) -> String {
        "Play now, \(title)"
    }

    /// Now Playing is empty when no session is open, or the open one has finished or been abandoned.
    /// A session that is playing, paused or recording holds it.
    public static func nowPlayingIsEmpty(sessionId: String?, phase: SessionPhase) -> Bool {
        guard sessionId != nil else { return true }
        return phase == .finished || phase == .abandoned
    }
}
