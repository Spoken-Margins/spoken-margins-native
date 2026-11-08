import Foundation
import SessionKit

/// Feedback reporting and banner replacement, moved unchanged from the model (#982).
extension Gate1AppModel {
    func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    /// Records a successful outcome and presents it only when the result is not
    /// otherwise apparent from the current interface.
    func reportConfirmation(_ message: String, action: UserFeedbackEvent.Action? = nil, fileID: String = #fileID, line: Int = #line) {
        reportSuccess(message)
        presentFeedback(UserFeedbackEvent(kind: .success, message: message, action: action), fileID: fileID, line: line)
    }

    /// Presents degraded-but-successful behavior without styling it as either a
    /// normal confirmation or a failure.
    func reportWarning(_ message: String, action: UserFeedbackEvent.Action? = nil, origin: FeedbackOrigin? = nil, fileID: String = #fileID, line: Int = #line) {
        statusMessage = message
        lastError = nil
        presentFeedback(UserFeedbackEvent(kind: .warning, message: message, action: action, origin: origin), fileID: fileID, line: line)
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    func reportFailure(_ error: Error, context: String? = nil, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil, fileID: String = #fileID, line: Int = #line) {
        let message: String
        let rawMessage: String
        if let urlError = error as? URLError {
            message = Self.userFacingMessage(for: urlError)
            rawMessage = message
        } else {
            message = ListenerErrorText.message(for: error)
            if let localized = error as? LocalizedError, let description = localized.errorDescription {
                rawMessage = description
            } else {
                rawMessage = String(describing: error)
            }
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "), itemId: itemId, retry: retry, fileID: fileID, line: line)
        // Bug reports keep the raw text (#1965); the banner and the item's failure line show the plain one.
        diagnostics["recentFailure"] = [context, rawMessage].compactMap { $0 }.joined(separator: ": ")
    }

    func reportFailure(_ message: String, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil, feedbackMessage: String? = nil, origin: FeedbackOrigin? = nil, fileID: String = #fileID, line: Int = #line) {
        statusMessage = "Error"
        lastError = message
        presentFeedback(UserFeedbackEvent(kind: .error, message: feedbackMessage ?? message, retry: retry, origin: origin), fileID: fileID, line: line)
        itemFailures.record(message, itemId: itemId, visibleItemId: screen == .item ? selectedItem.id : screen == .playback ? snapshot.itemId ?? "" : "")
        diagnostics["recentFailure"] = message
    }

    /// The one place a banner is put on screen. It also records a `feedback.shown` playback event (or
    /// `feedback.suppressed` when a banner already showing refuses the replacement), with no text (#3344).
    /// `fileID` and `line` default to the caller's, so a call site names itself without changing.
    func presentFeedback(_ event: UserFeedbackEvent, fileID: String = #fileID, line: Int = #line) {
        let replaced = feedbackEvent != nil
        let accepted = feedbackEvent?.mayBeReplaced(by: event) ?? true
        recordDeveloperDiagnostic(
            FeedbackShownEvent.kind(suppressed: !accepted),
            FeedbackShownEvent.fields(
                kind: event.kind, fileID: fileID, line: line, message: event.message,
                hasAction: event.action != nil || event.retry != nil, replaced: replaced, suppressed: !accepted
            )
        )
        guard accepted else { return }
        feedbackEvent = event
    }

    /// Drops the current event when it is about this item's own listen (a summary or a Margin transcription),
    /// so its Retry can't outlive the item when it moves to Recently Deleted or is deleted for good (#430).
    func withdrawFeedback(aboutItem itemId: String) {
        withdrawFeedback(aboutItems: [itemId])
    }

    func withdrawFeedback(aboutItems itemIds: [String]) {
        if let origin = feedbackEvent?.origin, itemIds.contains(origin.itemId) { feedbackEvent = nil }
    }

    /// The current event as the playback screen's one-line tag, or nil when it belongs in the top banner (#430).
    var playbackFeedbackTag: (event: UserFeedbackEvent, tag: PlaybackFeedbackTag)? {
        guard let event = feedbackEvent,
              let tag = PlaybackFeedbackTag(
                kind: event.kind,
                origin: event.origin,
                offersRetry: event.retry != nil,
                playbackScreenVisible: screen == .playback,
                playingItemId: snapshot.itemId,
                playingSessionId: snapshot.sessionId
              ) else { return nil }
        return (event, tag)
    }
}

extension Gate1AppModel {
    /// The sleep timer has paused playback: the banner and one soft tap, for a listener whose phone is face down (#1978).
    func sleepTimerExpired(_ mode: SleepTimerMode) {
        AppHaptics.play(.ended)
        reportConfirmation(SleepTimerPolicy.expiryConfirmation(mode: mode))
    }
}
