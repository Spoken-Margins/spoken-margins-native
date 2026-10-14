import Foundation

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
    func reportConfirmation(_ message: String, action: UserFeedbackEvent.Action? = nil) {
        reportSuccess(message)
        presentFeedback(UserFeedbackEvent(kind: .success, message: message, action: action))
    }

    /// Presents degraded-but-successful behavior without styling it as either a
    /// normal confirmation or a failure.
    func reportWarning(_ message: String) {
        statusMessage = message
        lastError = nil
        presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    func reportFailure(_ error: Error, context: String? = nil, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil) {
        let message: String
        if let urlError = error as? URLError {
            message = Self.userFacingMessage(for: urlError)
        } else if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "), itemId: itemId, retry: retry)
    }

    func reportFailure(_ message: String, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil, feedbackMessage: String? = nil) {
        statusMessage = "Error"
        lastError = message
        presentFeedback(UserFeedbackEvent(kind: .error, message: feedbackMessage ?? message, retry: retry))
        itemFailures.record(message, itemId: itemId, visibleItemId: screen == .item ? selectedItem.id : screen == .playback ? snapshot.itemId ?? "" : "")
        diagnostics["recentFailure"] = message
    }

    func presentFeedback(_ event: UserFeedbackEvent) {
        guard feedbackEvent?.mayBeReplaced(by: event) ?? true else { return }
        feedbackEvent = event
    }
}
