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
}

/// Hear it land: right after a new listener saves a Margin, the app plays it back in place (spoken) or shows its card
/// (written). Whether is `HearItLand.plan`; the playback is the ordinary Margin moment through `startMarginMoment`, so
/// nothing here is a player or a "should the source resume" flag. It sits in its own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// What else holds the screen or the microphone as the save finishes.
    private var hearItLandSurroundings: HearItLand.Surroundings {
        HearItLand.Surroundings(
            appInForeground: UIApplication.shared.applicationState == .active,
            recordingAgain: snapshot.isRecording || isRequestingRecordingPermission,
            anotherSheetUp: screen != .playback,
            speechCardShowing: SpeechAskController.shared.cardSurface != nil
        )
    }

    /// Called at the very end of a spoken save, after the engine's own resume, the held voice's resume and the speech queue's
    /// resume. The moment's seek back is the conductor's own `start()`; starting it before those would let their play call
    /// undo the seek (Design, "Playback uses the existing moment").
    /// - Parameters:
    ///   - savedId: the Margin this save made.
    ///   - hadSavedMarginBefore: `.firstInterjection` as it was before this save marked it.
    ///   - heldVoice: the Margin was recorded over a speaking Margin, which plays on as today (#1672).
    func hearItLandAfterSpokenSave(savedId: String?, hadSavedMarginBefore: Bool, heldVoice: Bool) {
        guard !snapshot.isRecording else { return }
        let plan = HearItLand.plan(
            kind: .spoken, heardFirstMargin: isOnboardingStepComplete(.heardFirstMargin), hadSavedMarginBefore: hadSavedMarginBefore,
            savedOverHeldVoice: heldVoice, sourcePlaysAfterSave: snapshot.status.isPlaybackActive, surroundings: hearItLandSurroundings)
        guard plan == .playBack, let savedId, let store, let sessionId = snapshot.sessionId,
              let saved = (try? store.loadInterjections(sessionId: sessionId))?.first(where: { $0.id == savedId }),
              saved.isSpokenItemMargin, abs(Date().timeIntervalSince(saved.createdAt)) < 10, // never an older Margin whose id was left behind
              let path = saved.audioPath, let voice = resolvedInterjectionAudioURL(for: path) else { return }
        let clock: MarginMomentClock = snapshot.targetType == TargetType.itemTextTTS.rawValue ? .liveNarration : .media
        let text = clock.isNarratedText ? (selectedItem.text(forItem: saved.itemId) ?? "") : ""
        guard let anchors = MarginMomentPlanner.anchors(
            played: saved, among: [], clock: clock, targetMediaTimeMs: snapshot.currentMediaTimeMs, text: text) else { return }
        endMarginMoment()
        HearItLandState.shared.aftermath.began(identity: anchors.target.marginId, at: Date())
        startMarginMoment(
            sequence: HearItLand.sequence(itemId: saved.itemId, target: anchors.target, tickAdvanceLimitMs: clock.tickAdvanceLimitMs),
            voiceURLs: [anchors.target.marginId: voice], title: "Your Margin", isApproximate: false, clock: clock)
        diagnostics["hearItLand"] = "playBack"
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

    /// A moment's voice stopped. The friend's answer-saved window counts from here when it was hear it land's.
    func hearItLandVoiceEnded(_ identity: String) {
        HearItLandState.shared.aftermath.voiceEnded(identity: identity, at: Date())
        objectWillChange.send()
    }

    /// The card's run for the open moment: `.hearItLand` while hear it land's own Margin plays.
    func hearItLandRun(forMomentTarget identity: String) -> PinnedMarginCard.Run {
        HearItLandState.shared.aftermath.run(forMomentTarget: identity)
    }

    /// The written first Margin's card, on the item it was saved on.
    var hearItLandWrittenCard: PinnedMarginCard? {
        HearItLandState.shared.aftermath.writtenCard(now: Date(), itemId: snapshot.itemId)
    }
}
