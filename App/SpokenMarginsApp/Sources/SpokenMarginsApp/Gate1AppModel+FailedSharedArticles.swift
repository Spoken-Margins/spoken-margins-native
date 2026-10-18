import Foundation

/// An article shared from Safari or another app that couldn't be added is announced, with a way to the Import
/// Inbox where each one can be retried or removed. The share sheet already said "Saved", so silence would
/// leave the listener waiting for an article that isn't coming (#1972).
extension Gate1AppModel {
    nonisolated static func failedSharedArticlesMessage(count: Int) -> String {
        count == 1 ? "1 shared article couldn't be added." : "\(count) shared articles couldn't be added."
    }

    func announceFailedSharedArticles(count: Int) {
        guard count > 0 else { return }
        let message = Self.failedSharedArticlesMessage(count: count)
        statusMessage = "Error"
        lastError = message
        presentFeedback(UserFeedbackEvent(
            kind: .error,
            message: message,
            action: UserFeedbackEvent.Action(
                title: "See why",
                accessibilityLabel: "See why the shared \(count == 1 ? "article" : "articles") couldn't be added",
                identifier: "feedback.sharedArticleFailed.seeWhy",
                perform: { [weak self] in self?.openSettings() }
            )
        ))
        diagnostics["recentFailure"] = message
    }
}
