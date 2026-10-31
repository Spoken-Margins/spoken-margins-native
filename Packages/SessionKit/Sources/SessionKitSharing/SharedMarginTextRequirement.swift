import Foundation
import SessionKit

/// A shared Margin must carry reviewed words. `SpokenMarginsPackageBuilder` and every
/// packet reader back to Build 29 reject an empty transcript, voice Margins included.
/// A voice Margin whose transcription failed or is still pending travels with placeholder
/// words (`SharedMarginPlaceholder`, #3027); a Margin with neither words nor voice can't go
/// in a packet, and leaving it out must never be silent (#304).
public enum SharedMarginTextRequirement {
    public static func hasReviewedText(_ approvedTranscript: String) -> Bool {
        !approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The words the sender starts reviewing with: cleaned, then raw, then display text, the first that has words
    /// (a blank cleaned transcript no longer hides the raw one, #3027).
    /// Both the count on the Share Margins button and the review sheet start here, so they agree (#1185).
    public static func initialReviewedText(for interjection: Interjection) -> String {
        [interjection.cleanedTranscript, interjection.transcript, interjection.displayText]
            .compactMap { $0 }
            .first(where: hasReviewedText) ?? ""
    }

    /// Whether a packet can carry this Margin: it has words, or it is a voice Margin, which travels with placeholder
    /// words when it has none (`SharedMarginPlaceholder`, #3027). Only a Margin with neither is left out.
    public static func canShare(_ interjection: Interjection, hasVoice: Bool) -> Bool {
        hasReviewedText(initialReviewedText(for: interjection))
            || SharedMarginPlaceholder.words(for: interjection, itemTitle: nil, hasVoice: hasVoice) != nil
    }

    /// The Margins the share sheet starts with included: only the starred ones when any
    /// are starred, otherwise all of them. `prepareShareInterjections` applies the same rule.
    public static func initiallyIncluded(_ interjections: [Interjection]) -> [Interjection] {
        let starred = interjections.filter { $0.isStarredForSharing == true }
        return starred.isEmpty ? interjections : starred
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

/// What a packet will actually carry out of the Margins the listener included (#1185).
/// A Margin with no reviewed words is "included" in the list but can't go in the packet,
/// so every count the listener sees must come from here, not from the include flags.
public struct SharedMarginSelectionSummary: Equatable, Sendable {
    /// Margins that will be in the packet: included and carrying reviewed words.
    public let packetCount: Int
    /// Included Margins that had to be left out for want of words.
    public let leftOutCount: Int

    public init<Margin>(
        _ margins: [Margin],
        isIncluded: (Margin) -> Bool,
        text: (Margin) -> String
    ) {
        let included = margins.filter(isIncluded)
        let shareable = included.filter { SharedMarginTextRequirement.hasReviewedText(text($0)) }
        packetCount = shareable.count
        leftOutCount = included.count - shareable.count
    }

    /// What to tell the listener about Margins left out; `nil` when nothing was.
    public var notice: String? {
        SharedMarginTextRequirement.omissionNotice(omitted: leftOutCount, remaining: packetCount)
    }
}
