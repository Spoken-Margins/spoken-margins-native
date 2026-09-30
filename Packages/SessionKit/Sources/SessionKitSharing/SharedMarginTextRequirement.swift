import Foundation

/// A shared Margin must carry reviewed words. `SpokenMarginsPackageBuilder` and every
/// packet reader back to Build 29 reject an empty transcript, voice Margins included,
/// so a Margin whose transcription failed or is still pending can't go in a packet.
/// Leaving it out must never be silent (#304).
public enum SharedMarginTextRequirement {
    public static func hasReviewedText(_ approvedTranscript: String) -> Bool {
        !approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Shown on the Margin itself while the listener reviews what to share.
    public static let reviewWarningText = "No transcript yet, so this Margin can't be shared. Retry its transcription in Margin detail."

    /// The review warning for a Margin with these words, or `nil` when it can be shared.
    public static func reviewWarning(for approvedTranscript: String) -> String? {
        hasReviewedText(approvedTranscript) ? nil : reviewWarningText
    }

    /// Splits the Margins the listener selected into those a packet can carry and the
    /// notice that says what was left out (`nil` when nothing was).
    public static func shareable<Margin>(
        _ selected: [Margin],
        text: (Margin) -> String
    ) -> (margins: [Margin], omission: String?) {
        let margins = selected.filter { hasReviewedText(text($0)) }
        return (margins, omissionNotice(omitted: selected.count - margins.count, remaining: margins.count))
    }

    /// What to tell the listener when selected Margins had to be left out. `nil` when
    /// nothing was left out. When nothing is left to share, it explains why.
    public static func omissionNotice(omitted: Int, remaining: Int) -> String? {
        guard omitted > 0 else { return nil }
        if remaining > 0 {
            return omitted == 1
                ? "1 Margin has no transcript and wasn't included."
                : "\(omitted) Margins have no transcript and weren't included."
        }
        return omitted == 1
            ? "The selected Margin has no transcript yet, so there's nothing to share. Retry its transcription in Margin detail."
            : "None of the selected Margins has a transcript yet, so there's nothing to share. Retry their transcription in Margin detail."
    }
}
