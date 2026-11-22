import SessionKit
import SessionKitAudio

extension Gate1AppModel {
    /// Shared post-save hook for the app, Live Activity and Watch completion routes.
    func transcribeAndRecordSavedSpokenMargin() {
        transcribeAndRecordSavedSpokenMargin(endedByPhrase: false)
    }

    /// `endedByPhrase` is true only when the spoken "stop margin" ended the Margin (#3940): the Margin is marked before
    /// its transcription is scheduled, so the job cuts the phrase from its audio and words. Every other save leaves it
    /// unmarked and keeps everything.
    func transcribeAndRecordSavedSpokenMargin(endedByPhrase: Bool) {
        guard let interjection = latestInterjectionNeedingTranscription() else { return }
        if endedByPhrase { MarginEndPhraseEndLedger.shared.markEndedByPhrase(interjectionId: interjection.id) }
        scheduleTranscription(for: interjection)
        recordSpokenMarginSignal(interjection)
    }

    /// A finish can save its Margin and then fail to resume playback (the engine saves first).
    /// `savedInterjectionId` is the Margin the engine last saved; it still counts, once.
    func recordSpokenMarginSavedBeforeFailure(_ savedInterjectionId: String?) {
        guard let savedInterjectionId, let sessionId = snapshot.sessionId,
              let interjections = try? store?.loadInterjections(sessionId: sessionId),
              let saved = interjections.first(where: { $0.id == savedInterjectionId }) else { return }
        recordSpokenMarginSignal(saved)
    }

    private func recordSpokenMarginSignal(_ interjection: Interjection) {
        listeningSignals.spokenMargin(sessionId: interjection.sessionId, interjectionId: interjection.id, itemId: interjection.itemId,
                                      audioURL: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)))
    }
}
