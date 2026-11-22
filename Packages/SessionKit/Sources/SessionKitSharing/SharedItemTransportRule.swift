import Foundation
import SessionKit

/// Which items may travel inside a packet as their own text (#2997).
///
/// A link-less text item (a pasted article, a text file) can be embedded in a packet when the sender confirms the
/// rights to it. A meeting transcript never is: it holds other people's words, and a friend who needs it has to
/// bring their own copy of the file. A shared Margin still carries its anchored words and the text just before and
/// after, as for any text item, so the friend's copy is matched by digest.
public enum SharedItemTransportRule {
    /// False for an item imported from a meeting transcript. The share review reads this (not the reference type
    /// itself) to decide whether to offer the embed-the-text switch, and `SharedMarginExport.itemTransport` reads it
    /// again as a backstop, so one place decides.
    public static func allowsEmbeddedText(_ item: Item) -> Bool {
        allowsEmbeddedText(externalReferenceType: item.externalReferenceType)
    }

    public static func allowsEmbeddedText(externalReferenceType: String?) -> Bool {
        externalReferenceType != TranscriptItemText.referenceType
    }
}
