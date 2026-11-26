import Foundation

/// What the Tidy version card on a Margin's details screen does for a Margin as it is stored now (#4339). Pure, so the
/// rules for "when is a tidy offered" are tested on the host and the view only draws the answer.
public enum MarginTidyCardState: Equatable, Sendable {
    /// No card: a written Margin, a transcript that isn't ready or is gone, a Margin the author already answered
    /// with "Keep mine", or one that already carries cleaned text this feature didn't write.
    case hidden
    /// Nothing was answered yet: ask `MarginTidyProposer` for a tidy version and show the card if it has one.
    case candidate(transcript: String)
    /// The author approved the tidy version: "Showing your tidy version." with a way back to the original words.
    case used

    public static func state(for margin: Interjection) -> MarginTidyCardState {
        guard margin.captureKind != .written, margin.status == "active" else { return .hidden }
        if let decision = margin.tidyDecision {
            switch decision.choice {
            case .usedTidy: return .used
            case .keptOriginal: return .hidden
            }
        }
        guard ["transcribed", "complete"].contains(margin.transcriptionStatus),
              let transcript = margin.transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .hidden }
        // Cleaned text with no answer came from somewhere else (an older build's cleanup): never write over it.
        if let cleaned = margin.cleanedTranscript, !cleaned.isEmpty { return .hidden }
        return .candidate(transcript: transcript)
    }

    /// Whether a list may say "Tidy version to review" for this Margin without asking the on-device model (#4338's export
    /// sheet, #4339): nothing answered yet, and the filler-only tidy, which every iPhone makes at once, differs from the
    /// words. Opening the card may then offer the model's rewrite instead; this only decides whether there is one to see.
    public static func hasTidyToReview(_ margin: Interjection) -> Bool {
        guard case .candidate(let transcript) = state(for: margin) else { return false }
        let tidy = MarginTidy.fillerOnly(transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        return !tidy.isEmpty && !MarginTidyProposer.sameWords(tidy, transcript)
    }

    /// The line under a proposal that says where it came from (the Design's caption).
    public static func caption(for source: MarginTidyProposal.Source) -> String {
        switch source {
        case .fillers: return "Fillers removed."
        case .onDeviceAI: return "Tidied on this iPhone, using the passage around it."
        }
    }

    /// The answer stored with an approved proposal.
    public static func decisionSource(for source: MarginTidyProposal.Source) -> MarginTidySource {
        switch source {
        case .fillers: return .fillers
        case .onDeviceAI: return .onDeviceAI
        }
    }
}
