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
    private var observers: [NSObjectProtocol] = []

    init(
        journal: WrittenMarginDraftJournal?,
        currentDraft: @escaping () -> WrittenMarginDraft?,
        onFailure: @escaping (String) -> Void
    ) {
        saver = WrittenMarginDraftSaver(journal: journal, onFailure: onFailure)
        self.currentDraft = currentDraft
        #if canImport(UIKit)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            })
        }
        #endif
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func textChanged(_ draft: WrittenMarginDraft) {
        saver.textChanged(draft.text, capture: draft.capture)
    }

    func discard(captureId: String) {
        saver.discard(captureId: captureId)
    }

    private func flush() {
        guard let draft = currentDraft() else { return }
        saver.flush(draft.text, capture: draft.capture)
    }
}
