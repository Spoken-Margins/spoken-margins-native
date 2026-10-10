import Foundation

/// How close to the start of a sentence or paragraph a Back tap counts as already being at the start (#1102).
///
/// Speech is always a few characters past the start of the unit it is reading, so "the boundary before the
/// position" is that same start again, and repeated Back taps never went further back. Within this window of a
/// start, or of where the last Back tap landed, Back goes to the start of the unit before it, as a music
/// player's Previous does in the first seconds of a track. Repeated taps then walk back one unit each.
///
/// The window is seconds of speech, so it follows the listener's speed: at 2× the same three seconds cover
/// twice the characters.
enum BackTapWindow {
    static let seconds = 3.0

    /// Written characters read in `seconds` at `speed` (1 is normal, 2 is double).
    static func characters(atSpeed speed: Double) -> Int {
        let safeSpeed = speed.isFinite && speed > 0 ? speed : 1
        return max(1, Int((seconds * ListeningTimeEstimator.defaultCharactersPerSecond * safeSpeed).rounded()))
    }
}
