import Foundation

/// Whether the Terms of Use must be answered before an item plays (#781).
///
/// The Terms cover the bundled on-device voices, James and Lily. Only text they would read (an article, a PDF,
/// pasted text) needs them. Recorded audio (a podcast episode, an imported audio file) uses no synthetic voice,
/// so it never meets the Terms. Until the Terms are accepted the app speaks with the iPhone voice anyway, so
/// James and Lily never synthesise anything before acceptance.
public enum PlaybackTermsGate {
    /// How the Terms sheet opens (#2853).
    public enum Presentation: Equatable, Sendable {
        /// First Play: a short summary, a link to the complete Terms, and the two actions, all on one screen.
        case summary
        /// The complete Terms in full, with the actions at the end. A voice the listener picks in Settings, and
        /// reading the Terms again, always get this.
        case complete
    }

    /// A first Play waiting on the Terms gets the summary; every other way in gets the complete Terms. A listener
    /// who chose the voice themselves has asked for it, and the Terms for it are shown whole.
    public static func presentation(playbackIsWaiting: Bool, termsAccepted: Bool) -> Presentation {
        playbackIsWaiting && !termsAccepted ? .summary : .complete
    }

    /// Whether the Terms can matter at all: the listener has not accepted them and chose James or Lily. A caller asks
    /// this first and reads the item only when it is true, so a Play tap after the Terms were answered reads nothing
    /// (#2506).
    public static func mayRequireTerms(termsAccepted: Bool, bundledVoicePending: Bool) -> Bool {
        !termsAccepted && bundledVoicePending
    }

    /// - Parameters:
    ///   - item: what is about to play; a Library summary is enough. Nil when it can't be loaded, which keeps the
    ///     gate, as before.
    ///   - bundledVoicePending: the listener chose James or Lily, waiting on the Terms.
    public static func requiresTerms(for item: (any LibraryItemFields)?, termsAccepted: Bool, bundledVoicePending: Bool) -> Bool {
        guard mayRequireTerms(termsAccepted: termsAccepted, bundledVoicePending: bundledVoicePending) else { return false }
        guard let item else { return true }
        return !playsRecordedAudio(item)
    }

    /// True when the item plays recorded audio rather than text read by a voice.
    public static func playsRecordedAudio(_ item: any LibraryItemFields) -> Bool {
        switch item.media?.sourceType {
        case .nativeMediaFile, .remoteStream, .browserOwnedMedia: true
        case .generatedTTSRealtime, .generatedTTSPrerendered, nil: false
        }
    }
}
