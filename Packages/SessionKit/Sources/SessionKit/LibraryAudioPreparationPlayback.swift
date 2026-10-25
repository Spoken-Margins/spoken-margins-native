import Foundation

/// When the Library may render audio ahead of listening (#2694).
///
/// A listener who is hearing an item in an on-device voice owns the speech renderer and the phone's
/// heat and CPU budget. Nothing is made available offline in the background then, however far ahead
/// playback is. The same holds after a relaunch that restored a speech session: the listener is
/// about to press play on an app that was just killed, or that fell back because the phone was
/// struggling, so the hold lasts until that playback starts or the listener asks for offline audio.
/// A podcast or other media item doesn't use the speech renderer, so it never holds the Library back.
public enum LibraryAudioPreparationPlayback {
    public static func allows(
        isMediaPlayback: Bool,
        isPlaybackActive: Bool,
        holdsForRestoredSpeech: Bool
    ) -> Bool {
        isMediaPlayback || (!isPlaybackActive && !holdsForRestoredSpeech)
    }
}
