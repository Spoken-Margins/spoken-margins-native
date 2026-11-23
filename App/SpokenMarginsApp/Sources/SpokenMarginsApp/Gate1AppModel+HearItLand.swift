import Foundation
import SessionKit
import SessionKitAudio
import UIKit

/// What hear it land keeps between the save and the cards (#4713). A holder of its own, not a stored property of
/// `Gate1AppModel` (a hot file at its ceiling), like `MarginEndPhraseStatus`. The rules are `HearItLandAftermath`, host-tested
/// in SessionKit.
@MainActor
final class HearItLandState {
    static let shared = HearItLandState()
    var aftermath = HearItLandAftermath()

    /// Back to nothing, for tests that share `shared`.
    func reset() { aftermath = HearItLandAftermath() }
}

/// Hear it land: right after a new listener saves a Margin, the app plays it back in place (spoken) or shows its card
/// (written). Whether is `HearItLand.order`; the playback is the ordinary Margin moment through `startMarginMoment`, so
/// nothing here is a player or a "should the source resume" flag. It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// What else holds the screen or the microphone as the save finishes.
    private var hearItLandSurroundings: HearItLand.Surroundings {
        HearItLand.Surroundings(
            appInForeground: UIApplication.shared.applicationState == .active,
            recordingAgain: snapshot.isRecording || isRequestingRecordingPermission,
            anotherSheetUp: screen != .playback)
    }

    /// Whether this spoken save plays back, decided **before** the speech ask hears of the save (#4715 Design: the playback
    /// first, then the ask). `finishInterjection` passes the answer to `transcribeAndRecordSavedSpokenMargin`.
    func hearItLandWillPlayBack(hadSavedMarginBefore: Bool, heldVoice: Bool) -> Bool {
        HearItLand.order(
            kind: .spoken, heardFirstMargin: isOnboardingStepComplete(.heardFirstMargin), hadSavedMarginBefore: hadSavedMarginBefore,
            savedOverHeldVoice: heldVoice, sourcePlaysAfterSave: snapshot.status.isPlaybackActive,
            surroundings: hearItLandSurroundings).plan == .playBack
    }

    /// Called at the very end of a spoken save, after the engine's own resume, the held voice's resume and the speech queue's
    /// resume. The moment's seek back is the conductor's own `start()`; starting it before those would let their play call
    /// undo the seek (Design, "Playback uses the existing moment"). `willPlayBack` is `hearItLandWillPlayBack`'s answer; the
    /// speech card has been waiting for it, so when the playback can't start it is let go here.
    func hearItLandAfterSpokenSave(willPlayBack: Bool, savedId: String?) {
        guard willPlayBack else { return }
        guard !snapshot.isRecording, let savedId, let store, let sessionId = snapshot.sessionId,
              let interjections = try? store.loadInterjections(sessionId: sessionId) else { return hearItLandPlaybackDidNotStart() }
        let clock: MarginMomentClock = snapshot.targetType == TargetType.itemTextTTS.rawValue ? .liveNarration : .media
        guard let playback = HearItLand.savedPlayback(
                savedId: savedId, among: interjections, now: Date(), clock: clock, targetMediaTimeMs: snapshot.currentMediaTimeMs,
                textForItem: { selectedItem.text(forItem: $0) ?? "" }),
              let path = playback.saved.audioPath, let voice = resolvedInterjectionAudioURL(for: path) else {
            return hearItLandPlaybackDidNotStart()
        }
        endMarginMoment()
        HearItLandState.shared.aftermath.began(identity: playback.target.marginId, at: Date())
        startMarginMoment(
            sequence: HearItLand.sequence(itemId: playback.saved.itemId, target: playback.target, tickAdvanceLimitMs: clock.tickAdvanceLimitMs),
            voiceURLs: [playback.target.marginId: voice], title: "Your Margin", isApproximate: false, clock: clock)
        diagnostics["hearItLand"] = "playBack"
    }

    /// The playback the speech card waited for will not run.
    private func hearItLandPlaybackDidNotStart() {
        diagnostics["hearItLand"] = "playBackFailedToStart"
        SpeechAskController.shared.hearItLandEnded()
    }

    /// Called when a written Margin is saved: the card shows, and the event "first Margin heard" fires (#4711, rule 2).
    func hearItLandAfterWrittenSave(itemId: String, atMs: Int?) {
        let plan = HearItLand.plan(
            kind: .written, heardFirstMargin: isOnboardingStepComplete(.heardFirstMargin),
            hadSavedMarginBefore: isOnboardingStepComplete(.firstInterjection), savedOverHeldVoice: false, sourcePlaysAfterSave: false)
        guard plan == .showWritten else { return }
        HearItLandState.shared.aftermath.wrote(itemId: itemId, atMs: atMs, at: Date())
        noteMarginHeard(MarginHearing(isListenersOwn: true, kind: .written, outcome: .savedAndShown))
        diagnostics["hearItLand"] = "showWritten"
        objectWillChange.send()
    }

    /// A moment's voice stopped. The friend's answer-saved window counts from here when it was hear it land's, and the
    /// speech card that waited for the playback may show (#4715).
    func hearItLandVoiceEnded(_ identity: String) {
        if HearItLandState.shared.aftermath.voiceEnded(identity: identity, at: Date()) { SpeechAskController.shared.hearItLandEnded() }
        objectWillChange.send()
    }

    /// The moment ended before its voice did (another item, a recording, leaving playback). Forgets the playback, so a later
    /// "Play this moment" of the Margin keeps the ordinary card, and lets the speech card show.
    func hearItLandPlaybackCancelled() {
        if HearItLandState.shared.aftermath.cancelled() { SpeechAskController.shared.hearItLandEnded() }
    }

    /// The card's run for the open moment: `.hearItLand` while hear it land's own Margin plays.
    func hearItLandRun(forMomentTarget identity: String) -> PinnedMarginCard.Run {
        HearItLandState.shared.aftermath.run(forMomentTarget: identity, now: Date())
    }

    /// The written first Margin's card, on the item it was saved on.
    var hearItLandWrittenCard: PinnedMarginCard? {
        HearItLandState.shared.aftermath.writtenCard(now: Date(), itemId: snapshot.itemId)
    }
}
