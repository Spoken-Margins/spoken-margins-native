import AVFoundation
import Foundation
import SessionKit
import UIKit

/// The Footnote card on the Now screen (#3777, Design PR 5): which note, if any, the narrator is reading where it is
/// cited. The words are `FootnoteCard` and the plan rules behind it are `FootnoteNoteControls`, both in SessionKit; this
/// reads the player into them. It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// Whether the card could be showing: the open item is the one playing, it is not a podcast, and the on-device voice
    /// (the only player with note chunks) is reading a plan that has notes in it. The card's view polls the player only
    /// while this is true, so an article without notes, or any other item, costs nothing.
    var footnoteCardMayShow: Bool {
        guard !selectedItem.isNativeAudio, snapshot.itemId == selectedItem.id,
              snapshot.status.isPlaybackActive || snapshot.status == .paused,
              let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else { return false }
        return client.hasFootnoteAsides
    }

    /// The card for the note being read, or nil. A friend's pinned card wins and the note is not shown for that listen at
    /// all: it does not queue behind the friend's card, and the note stays in the notes chapter (Design, Screens).
    var footnoteCard: FootnoteCard? {
        // The player's answer comes first: `pinnedMarginCard` builds a good deal, and a note is the rare case.
        guard footnoteCardMayShow, let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else { return nil }
        // "Chime where cited": an offered note's card goes after 30 seconds, and never while VoiceOver is running, because
        // the app can't see where its focus is (Design, Flow 5).
        client.expireChimeCardIfDue(voiceOverIsOnCard: UIAccessibility.isVoiceOverRunning)
        guard let card = client.currentFootnoteCard(), pinnedMarginCard == nil else { return nil }
        return card
    }

    /// "Reading" is in the card's header while the note's own words are playing; a note paused on is shown without it. A
    /// note the chime only offered is not being read: the text carries on, so playing says nothing about it.
    var footnoteCardIsReading: Bool {
        if let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient, case .offered = client.chimeCardState() {
            return false
        }
        return snapshot.status.isPlaybackActive
    }

    /// The card's button: Hear note while a chime offers a note, Stop note while the listener's request for it reads. Nil
    /// in the other modes, where the card has no button (Design, Screens).
    var footnoteCardButton: FootnoteCardButton? {
        // Only while playing: a seek on a paused session moves its place and plays nothing, so the button would do nothing.
        guard snapshot.status.isPlaybackActive,
              let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else { return nil }
        switch client.chimeCardState() {
        case .hidden: return nil
        case .offered: return .hearNote
        case .reading: return .stopNote
        }
    }

    /// The card's button was pressed.
    func footnoteCardButtonPressed(_ button: FootnoteCardButton) {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else { return }
        // The move is a text seek through the engine, as Back and Skim are, so the session, the Lock Screen and the card agree
        // where playback is. A seek on a paused session moves its place; the listener's play then reads the note.
        let offset: Int?
        switch button {
        case .hearNote: offset = client.beginHearingOfferedFootnote()
        case .stopNote: offset = client.beginStoppingFootnote()
        }
        guard let offset else { return }
        if !seekText(toCharOffset: offset) { client.footnoteMoveFailed() }
    }
}

/// The soft tone that marks a cited note in "Chime where cited" (#3777). Like the voice-change chime it never configures
/// the audio session: it plays only when narration has already put the session in its `.playback` category, which it has
/// when a passage follows another one. The tone is `FootnoteCue`, built in memory, so the app ships no sound file.
final class FootnoteChimeCuePlayer: @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVAudioPlayer?

    /// Returns what it did, for tests and diagnostics: "played" or "skipped:<why>".
    @discardableResult
    func play() -> String {
        #if os(iOS)
        guard AVAudioSession.sharedInstance().category == .playback else { return "skipped:session_not_playback" }
        #endif
        do {
            let tone = try AVAudioPlayer(data: FootnoteCue.wavData())
            tone.volume = 1
            lock.withLock { player = tone }
            return tone.play() ? "played" : "skipped:player_refused"
        } catch {
            return "skipped:\(SafeErrorText.describe(error))"
        }
    }
}
