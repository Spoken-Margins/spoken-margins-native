import Foundation

/// Plain words for packet values the sender's recipient preview shows (#5336). The preview is read back from the
/// verified archive, so it holds packet codes such as `text_only` or `model_generated`; those codes never reach the
/// screen. Every case is spelled out in a switch, so a new packet value can't fall through to its raw code.
public enum SharePreviewWords {
    /// The version of a Margin the friend gets, in the words the Choose and Review cards use ("As recorded",
    /// "Without ums", "Words only"). Nil is a Margin with no default representation.
    public static func version(_ kind: SharedInterjectionRepresentationKind?) -> String {
        switch kind {
        case .originalAudioAndText: ShareCleanupWords.asRecorded
        case .cleanedAudioAndText: ShareCleanupWords.withoutUms
        case .textOnly: ShareCleanupWords.wordsOnly
        case .summaryText: "Summary, words only"
        case .summaryAudioAndText: "Spoken summary"
        case .ttsAudioAndText: "Read by the phone's voice"
        case nil: "Version unavailable"
        }
    }

    /// Who wrote a Listening Map scene's summary, for the preview's disclosure line. Nil is a scene with no provenance.
    public static func summarySource(_ provenance: PortableSummaryProvenance?) -> String {
        switch provenance {
        case .publisherSupplied: "from the publisher"
        case .senderAuthored: "written by the sender"
        case .deterministic: "taken from the text"
        case .modelGenerated: "written by the on-device model"
        case nil: "source unknown"
        }
    }
}
