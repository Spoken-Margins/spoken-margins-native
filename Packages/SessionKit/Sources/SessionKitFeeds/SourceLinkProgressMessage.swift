import Foundation

/// What the add flow says while a pasted link resolves (#5049). An arXiv abstract page once sat behind a bare spinner
/// for about 41 seconds; the listener now reads what the app is doing, and a second line once the wait runs long, so a
/// slow page never looks stuck. The words are the listener's, never "resolving" or "source".
public enum SourceLinkProgressMessage {
    /// Shown, and read by VoiceOver, the moment a link starts resolving.
    public static let looking = "Looking for something to play…"
    /// Replaces `looking` once a link has resolved for `stillLookingAfter` seconds.
    public static let stillLooking = "Still looking. Some pages take up to a minute."
    /// Most links resolve in a few seconds (a PDF link added within 5 s on the Test Desk), so the second line shows only
    /// on a wait the listener would notice.
    public static let stillLookingAfter: TimeInterval = 10

    /// The line for a link that has been resolving for `elapsed` seconds.
    public static func text(elapsed: TimeInterval) -> String {
        elapsed >= stillLookingAfter ? stillLooking : looking
    }

    /// True for a line this type wrote, so a later stage replaces only its own words, never a result or failure.
    public static func isProgress(_ message: String?) -> Bool {
        message == looking || message == stillLooking
    }
}
