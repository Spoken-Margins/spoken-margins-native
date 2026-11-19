import Foundation

/// A tap asked for a Margin's place, and it has none (#4233).
///
/// A Margin moved from a live session with no playback position stored has `Interjection.hasPlace == false`: its anchor
/// and percent are zeros that mean nothing. Going to it would play the start of the item and say it was the Margin's
/// moment. Its own type, not a `SessionKitError` case, so a place the engine cannot find for any other reason keeps
/// the error it had; the app words this one on its own ("This Margin has no place in the source.").
public enum MarginPlaceError: Error, Equatable, Sendable {
    case noPlace
}
