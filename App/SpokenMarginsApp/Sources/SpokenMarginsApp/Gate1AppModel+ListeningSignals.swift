import SessionKit

extension Gate1AppModel {
    /// Shared post-save hook for the app, Live Activity and Watch completion routes.
    func transcribeAndRecordSavedSpokenMargin() {
        guard let interjection = latestInterjectionNeedingTranscription() else { return }
        scheduleTranscription(for: interjection)
        listeningSignals.spokenMargin(itemId: interjection.itemId, audioURL: interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)))
    }
}
