import Foundation

/// Whether an item the listener opened or started should have its post page read for a voiceover (#2789), and when
/// not, why. Opening the Item screen and pressing Play share it, so Library Play, Continue, the play queue and a
/// Following entry behave alike. A page is read only here and in the listener-started Following import, never in the
/// background (the owner's 2026-10-21 call, #2368).
public enum VoiceoverLookupDecision: Equatable, Sendable {
    case lookUp(address: String)
    /// `reason` is a short token for Diagnostics: no address, title or text.
    case skip(reason: String)

    public static func decide(
        text: String?,
        externalReference: String?,
        hasPublisherAudioRecord: Bool,
        alreadyLookedUp: Bool
    ) -> VoiceoverLookupDecision {
        if alreadyLookedUp { return .skip(reason: "already_looked_up") }
        if text?.isEmpty != false { return .skip(reason: "no_text") }
        guard let address = externalReference, let url = URL(string: address) else { return .skip(reason: "no_address") }
        if !PublisherNarrationEvidence.mayHaveVoiceover(url) { return .skip(reason: "not_substack_address") }
        if hasPublisherAudioRecord { return .skip(reason: "has_record") }
        return .lookUp(address: address)
    }
}
