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
        Task { [weak self] in
            // Every read, `currentMargin`'s included, runs off the main thread (#2256); only the retry bookkeeping and
            // scheduling come back here.
            let due = (try? await Self.offMain { () -> [Interjection] in
                identities.compactMap { identity in
                    guard let (sessionId, interjectionId) = MarginIdentity.split(identity),
                          let margin = try? store.loadInterjection(id: interjectionId, sessionId: sessionId) else { return nil }
                    let current = (try? store.loadInterjections(sessionId: sessionId))?.first { $0.id == interjectionId }
                    let itemDeletedAt = (try? store.loadItemSummary(id: margin.itemId))?.deletedAt
                    guard MarginTranscriptionRetry.verdict(current: current, itemDeletedAt: itemDeletedAt) == .retry else { return nil }
                    return current
                }
            }) ?? []
            guard let self else { return }
            hangTelemetry.labels.scoped("speechAskRetryWaiting") { scheduleWaitingRetries(due) }
        }
    }

    private func scheduleWaitingRetries(_ margins: [Interjection]) {
        for current in margins where retryingInterjectionTranscriptionIds.insert(Self.marginIdentity(current)).inserted {
            scheduleRetriedTranscription(for: current)
        }
    }

    /// A Margin's source-window transcription met the hold: Allow schedules it again (unless the Margin itself waits, whose
    /// retry brings its source window after it). Any other failure is the caller's to report.
    func noteSourceWindowHeld(_ interjection: Interjection, error: Error) {
        guard HeldTranscription.isHold(error) else { return }
        SpeechAskController.shared.transcriptionHeld(.sourceWindow, key: Self.marginIdentity(interjection)) { [weak self] in
            self?.scheduleSourceWindowContextIfNeeded(for: interjection)
        }
    }

    /// A transcription failure that is only the hold: the Margin waits for the listener's answer. Nothing to report.
    func noteTranscriptionWaitsForAnswer(_ interjection: Interjection, failure: String) {
        guard TranscriptionFailureWording.isSpeechRecognitionNotYetAsked(error: failure) else { return }
        SpeechAskController.shared.marginIsWaiting(marginIdentity: Self.marginIdentity(interjection))
    }
}
