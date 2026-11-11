import Foundation

/// A start of text speech from a place with nothing left to read (#4067).
///
/// The speech clients refuse such a start (`playback_text_empty`), and the generic "Something went wrong" banner was
/// what the listener saw: on a Margin saved at the end of the text, on "Go to this moment" there, on Save after the
/// speech ended unseen. The engine reads the refusal as the end of the text. It holds only while the session is where
/// it was when the start was refused: any move (a seek, a skip) clears it, and a new start replaces it.
struct EmptyTextStart: Equatable {
    var sessionId: String
    var targetId: String

    init(session: Session) {
        sessionId = session.id
        targetId = session.currentTargetId
    }

    func matches(_ session: Session) -> Bool {
        session.id == sessionId && session.currentTargetId == targetId
    }

    /// The reasons the system-speech and Supertonic clients give. Matching the suffix keeps a client's own prefix
    /// (`supertonic_`) from needing an entry of its own.
    static func isNothingLeftToRead(_ reason: String) -> Bool {
        reason == "playback_text_empty" || reason.hasSuffix("_playback_text_empty")
    }
}
