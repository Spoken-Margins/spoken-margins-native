import Foundation

/// The words that go out beside a share link (#3787). A bare address reads as spam to a friend who has never heard of
/// the app, so the share sheet carries one sentence with it. The sentence is the owner's pick of 2026-11-09.
///
/// The sentence and the address travel as one text, not as a text item beside a URL item: Messages and Mail show both
/// of two items, but other apps keep one and drop the other, and a friend who gets only the address is back where
/// this started. The sender can edit the text in whatever app takes it, as with any shared text. The link's own
/// preview stays sealed and generic (#486); nothing here touches it.
public enum ShareLinkMessage {
    public static let sentence = "I left you a voice note on a podcast. Tap the link, then Play. It works in your browser, nothing to install."

    /// The sentence, a blank line, then the whole address (its `#` key included).
    public static func text(for link: URL) -> String {
        "\(sentence)\n\n\(link.absoluteString)"
    }
}
