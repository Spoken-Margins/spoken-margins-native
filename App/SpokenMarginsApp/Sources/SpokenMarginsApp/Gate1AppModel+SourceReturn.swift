import Foundation
import SessionKit

/// The return to the source after a Margin's voice, which survives a refused start (#4110).
extension Gate1AppModel {
    /// One retrier for the app: a return that starts over replaces one still waiting.
    static let marginReturnResume = MarginReturnResume()

    /// The last step of `resumePlayback()`, kept here so the hot file doesn't grow (#4110).
    func startSourceAgain(returningFromMargin: Bool) {
        if returningFromMargin, resumeSourceAfterMargin() { return }
        run { engine in
            snapshot = try engine.resumePlayback()
            refreshSelectedItemInBackground() // like pause(): the icon flips without waiting for the item reload (#2098)
            reportSuccess("Resumed.")
        }
    }

    /// Starts the paused source again. Returns false only when there is no engine yet, so the caller's plain path runs.
    /// A refusal (iOS declining the audio session in the background) is recorded as `margin.return_resume`, retried
    /// with the interruption retrier's waits while the source is still paused where it was, and, when every retry is
    /// refused or the retry window has passed with the source still paused, shown as a banner with a Retry button.
    /// Nothing is shown for a refusal a retry cures.
    func resumeSourceAfterMargin() -> Bool {
        guard engine != nil else { return false }
        let sessionId = snapshot.sessionId
        let targetId = snapshot.targetId
        let pausedAtMs = snapshot.currentMediaTimeMs // a seek, skip, Play or Pause by the listener moves this, and then the source is theirs
        // A text or PDF source has no media time, so its place is the text offset and progress.
        let pausedAtText = snapshot.currentTextStart
        let pausedAtPercent = snapshot.progressPercent
        let sourceIsStillOwed: @MainActor () -> Bool = { [weak self] in
            self?.sourceIsStillOwedAfterMargin(sessionId: sessionId, targetId: targetId, pausedAtMs: pausedAtMs,
                                         pausedAtText: pausedAtText, pausedAtPercent: pausedAtPercent) ?? false
        }
        let resumedAtOnce = Self.marginReturnResume.resume(
            stillWaiting: sourceIsStillOwed,
            attempt: { [weak self] in
                guard let self, let engine = self.engine else { throw SessionKitError.invalidCommandForState("resumePlayback") } // read now: the engine can be replaced while a retry waits
                try hangTelemetry.labels.scoped(Self.engineRunLabel(caller: "resumeSourceAfterMargin")) {
                    snapshot = try engine.resumePlayback()
                }
                refreshSelectedItemInBackground()
            },
            report: { [weak self] event in
                guard let self else { return }
                recordDeveloperDiagnostic(MarginReturnResume.Event.recordKind, event.fields)
                switch event {
                case .resumedOnRetry:
                    reportSuccess("Resumed.")
                case .gaveUp:
                    reportPausedAfterMargin()
                case .abandoned:
                    // Either the listener took over, or the app was suspended while it waited (the likely locked phone).
                    // Only the second leaves the source paused where it was, so only then is the listener told.
                    if sourceIsStillOwed() { reportPausedAfterMargin() }
                case .failed, .retryFailed:
                    break
                }
            }
        )
        if resumedAtOnce { reportSuccess("Resumed.") }
        return true
    }

    private func reportPausedAfterMargin() {
        reportFailure(
            "Playback paused after the Margin and could not resume. Tap Retry to carry on.",
            retry: UserFeedbackEvent.Retry(key: "margin-return-resume", action: { [weak self] in self?.resumePlayback() })
        )
    }

    /// True while the source sits paused where the Margin left it and nothing else has the transport. The same owners
    /// `resumePlayback()` hands Play to before it starts the source: a Margin or moment voice, your own Margin's voice,
    /// a Skim bridge, a recording; and not an offer card up (the offer paused the source). A text or PDF source is
    /// held to its text offset and progress, since it has no media time.
    private func sourceIsStillOwedAfterMargin(sessionId: String?, targetId: String?, pausedAtMs: Int?,
                                              pausedAtText: Int?, pausedAtPercent: Int) -> Bool {
        snapshot.status == .paused && snapshot.sessionId == sessionId && snapshot.targetId == targetId
            && snapshot.currentMediaTimeMs == pausedAtMs && snapshot.currentTextStart == pausedAtText
            && snapshot.progressPercent == pausedAtPercent && !snapshot.isRecording
            && pendingImportedCommentary == nil && playingImportedCommentary == nil && !marginVoiceIsHeldForRecording
            && marginMomentConductor?.isPlayingVoice != true && marginMomentConductor?.isVoicePaused != true
            && !ownMarginVoiceHasTransport && snapshot.skimBridgeState == nil
    }
}
