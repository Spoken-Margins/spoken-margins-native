import Foundation
import SessionKit

/// #4715 / #5016: the model's side of the Speech Recognition card. The decisions are `SpeechRecognitionAsk` and the
/// carrying-out is `SpeechAskController`; this is only what needs the model's store and transcription path. It sits in its
/// own file so `Gate1AppModel` does not grow.
extension Gate1AppModel {
    /// Allow: transcribes the Margins that waited, oldest first, through the same retry a tap on Retry uses (and its
    /// source-window context after it). Quiet: the listener's own Yes is the confirmation, so no "Retranscribing" banner.
    /// A Margin deleted while it waited is skipped. `identities` are `marginIdentity` values ("session::margin").
    func retryWaitingTranscriptions(identities: [String]) {
        guard let store else { return }
        for identity in identities {
            guard let (sessionId, interjectionId) = MarginIdentity.split(identity),
                  let margin = try? store.loadInterjection(id: interjectionId, sessionId: sessionId) else { continue }
            let (current, verdict) = currentMargin(matching: margin)
            guard verdict == .retry, let current,
                  retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(current)).inserted else { continue }
            scheduleRetriedTranscription(for: current)
        }
    }

    /// Allow: places again the imported podcasts whose source transcription met the hold. They have no Margin on the waiting
    /// list, so `SpeechAuthorizationAsk` remembered their item ids.
    func retryHeldSourceTranscriptions(itemIds: [String]) {
        for itemId in itemIds { importedPodcastPlacement.retryAfterSpeechAllowed(itemId: itemId) }
    }

    /// A transcription failure that is only the hold: the Margin waits for the listener's answer. Nothing to report.
    func noteTranscriptionWaitsForAnswer(_ interjection: Interjection, failure: String) {
        guard TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: failure) else { return }
        SpeechAskController.shared.marginIsWaiting(marginIdentity: Self.marginIdentity(interjection))
    }
}
