import Foundation
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// Keeps the text of a written Margin that is still being typed (#1970), so a call, a memory kill or a swipe-away
/// doesn't lose it. It writes when typing pauses and again when the app leaves the screen, and it clears the draft
/// when the Margin is saved or discarded. `Gate1AppModel+WrittenMarginDrafts.swift` is the only caller.
@MainActor
final class WrittenMarginDraftKeeper {
    let saver: WrittenMarginDraftSaver
    private let currentDraft: () -> WrittenMarginDraft?

    init(
        journal: WrittenMarginDraftJournal?,
        currentDraft: @escaping () -> WrittenMarginDraft?,
        onFailure: @escaping (String) -> Void
    ) {
        saver = WrittenMarginDraftSaver(journal: journal, onFailure: onFailure)
        self.currentDraft = currentDraft
        #if canImport(UIKit)
        // The keeper lives as long as the model, and the observers hold it weakly, so they are never removed.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        #endif
    }

    func textChanged(_ draft: WrittenMarginDraft) {
        saver.textChanged(draft.text, capture: draft.capture.replying(to: draft.reply?.link))
    }

    func discard(captureId: String) {
        saver.discard(captureId: captureId)
    }

    private func flush() {
        guard let draft = currentDraft() else { return }
        saver.flush(draft.text, capture: draft.capture.replying(to: draft.reply?.link))
    }
}
