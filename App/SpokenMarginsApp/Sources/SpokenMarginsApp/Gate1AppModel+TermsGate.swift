import Foundation
import SessionKit
import SessionKitPersistence

/// The Terms sheet before the first playback read by James or Lily (#781).
extension Gate1AppModel {
    func requireTermsDecisionBeforePlayback(_ action: PendingPlaybackAfterTerms) -> Bool {
        // Almost every Play lands here with the Terms answered, so the item is read only when they could matter.
        let bundledVoicePending = pendingTermsVoiceSelection?.isOnDeviceVoice == true
        guard PlaybackTermsGate.mayRequireTerms(
            termsAccepted: hasAcceptedCurrentTerms, bundledVoicePending: bundledVoicePending
        ) else {
            return false
        }
        // The item the action plays: chapter jumps and play-from-start go through ensureSessionForSelectedItem,
        // which plays activeItemId, like start().
        let itemId: String? = switch action {
        case .startCurrentItem, .jumpToChapter, .playSourceFromBeginning: activeItemId
        case .resumeSession(let sessionId): (try? store?.loadSession(id: sessionId))?.itemId
        }
        // The summary carries the source type the gate looks at, without the item's text.
        let item = itemId.flatMap { id in try? store?.loadItemSummary(id: id) }
        // Only text read by James or Lily needs the Terms; a podcast never does (#781).
        guard PlaybackTermsGate.requiresTerms(
            for: item, termsAccepted: hasAcceptedCurrentTerms, bundledVoicePending: bundledVoicePending
        ) else {
            return false
        }
        pendingPlaybackAfterTerms = action
        isTermsOfUsePresented = true
        diagnostics["termsGate"] = "presented_for_first_playback"
        statusMessage = "Choose whether to enable the improved on-device voice before playback begins."
        return true
    }
}
