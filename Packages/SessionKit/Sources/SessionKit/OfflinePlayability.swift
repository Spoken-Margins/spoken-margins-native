import Foundation

/// Whether one item can play with no network connection (#779): the answer the pre-play check, and later the
/// trip Pack and the Library rows, show the listener. See docs/design/offline-trip-prep.md, "OfflinePlayability".
///
/// Pure: the app gathers the facts (is the episode's audio on the phone, is the text stored, how much of its
/// voice is prepared) and this decides.
public enum OfflinePlayability: String, Equatable, Sendable {
    /// Everything plays from files on the phone.
    case playsOffline = "plays_offline"
    /// It plays with no signal, but part of it is read by the live on-device voice instead of prepared audio.
    case playsPartlyOffline = "plays_partly_offline"
    /// Nothing playable is on the phone.
    case needsSignal = "needs_signal"

    public enum Source: Equatable, Sendable {
        /// A podcast episode or other audio item. `hasSavedAudio`: a downloaded or imported file is on the phone now.
        case audio(hasSavedAudio: Bool)
        /// An article, PDF or other item read aloud. `hasStoredText`: its text is saved in the Library.
        case text(hasStoredText: Bool, preparedAudio: PreparedAudio)
    }

    /// How much of a text item's voice has been rendered to files ahead of time.
    public enum PreparedAudio: Equatable, Sendable {
        case none
        case partial
        case complete
    }

    public init(_ source: Source) {
        switch source {
        case .audio(let hasSavedAudio):
            self = hasSavedAudio ? .playsOffline : .needsSignal
        case .text(let hasStoredText, let preparedAudio):
            guard hasStoredText else {
                self = .needsSignal
                return
            }
            self = preparedAudio == .complete ? .playsOffline : .playsPartlyOffline
        }
    }

    public static let episodeNotDownloadedMessage = "This episode isn't downloaded, and there's no signal."
    /// Only for a saved file that exists and still didn't play: replacing it can help.
    public static let savedAudioDidNotStartMessage =
        "Podcast playback did not start. Use Download Again in More to replace the saved audio, then press Play."
    public static let streamDidNotStartMessage = "Podcast playback did not start. Check your connection, then press Play."

    /// Before an episode starts: the message to show instead of trying, or nil to go ahead.
    /// Only a known-offline phone blocks; an unknown network state lets playback try.
    public static func episodeStartBlockedMessage(hasSavedAudio: Bool, isOffline: Bool) -> String? {
        guard isOffline, OfflinePlayability(.audio(hasSavedAudio: hasSavedAudio)) == .needsSignal else { return nil }
        return episodeNotDownloadedMessage
    }

    /// When an episode was asked to play and is still starting after the stall timeout.
    /// "Download Again" is offered only when a saved file exists, since only then can replacing it help.
    public static func episodeStalledMessage(hasSavedAudio: Bool, isOffline: Bool) -> String {
        if hasSavedAudio { return savedAudioDidNotStartMessage }
        return isOffline ? episodeNotDownloadedMessage : streamDidNotStartMessage
    }
}
