import Foundation
import SessionKit
import SessionKitPersistence

/// The Terms sheet before the first playback read by James or Lily (#781).
extension Gate1AppModel {
    func requireTermsDecisionBeforePlayback(_ action: PendingPlaybackAfterTerms) -> Bool {
        // The item the action plays: chapter jumps and play-from-start go through ensureSessionForSelectedItem,
        // which plays activeItemId, like start().
        let itemId: String? = switch action {
        case .startCurrentItem, .jumpToChapter, .playSourceFromBeginning: activeItemId
        case .resumeSession(let sessionId): (try? store?.loadSession(id: sessionId))?.itemId
        }
        let item = itemId.flatMap { id in try? store?.loadItem(id: id) }
        // Only text read by James or Lily needs the Terms; a podcast never does (#781).
        guard PlaybackTermsGate.requiresTerms(
            for: item, termsAccepted: hasAcceptedCurrentTerms,
            bundledVoicePending: pendingTermsVoiceSelection?.isOnDeviceVoice == true
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
