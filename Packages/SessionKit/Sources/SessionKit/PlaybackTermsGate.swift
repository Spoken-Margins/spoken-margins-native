import Foundation

/// Whether the Terms of Use must be answered before an item plays (#781).
///
/// The Terms cover the bundled on-device voices, James and Lily. Only text they would read (an article, a PDF,
/// pasted text) needs them. Recorded audio (a podcast episode, an imported audio file) uses no synthetic voice,
/// so it never meets the Terms. Until the Terms are accepted the app speaks with the iPhone voice anyway, so
/// James and Lily never synthesise anything before acceptance.
public enum PlaybackTermsGate {
    /// - Parameters:
    ///   - item: what is about to play. Nil when it can't be loaded, which keeps the gate, as before.
    ///   - bundledVoicePending: the listener chose James or Lily, waiting on the Terms.
    public static func requiresTerms(for item: Item?, termsAccepted: Bool, bundledVoicePending: Bool) -> Bool {
        guard !termsAccepted, bundledVoicePending else { return false }
        guard let item else { return true }
        return !playsRecordedAudio(item)
    }

    /// True when the item plays recorded audio rather than text read by a voice.
    public static func playsRecordedAudio(_ item: Item) -> Bool {
        switch item.media?.sourceType {
        case .nativeMediaFile, .remoteStream, .browserOwnedMedia: true
        case .generatedTTSRealtime, .generatedTTSPrerendered, nil: false
        }
    }
}
