import Foundation
import SessionKit

/// A written Margin the app was closed in the middle of (#1970). The text is journaled while it is typed; the next
/// launch reopens the written-Margin screen with it. The journal is a small file beside the recordings, never the
/// database, so the previous build opens the database unchanged.
extension Gate1AppModel {
    private var writtenMarginDraftKeeper: WrittenMarginDraftKeeper {
        if let keeper = marginCapture.draftKeeper { return keeper }
        let journal = (try? applicationSupportDirectory()).map {
            WrittenMarginDraftJournal(directory: WrittenMarginDraftJournal.standardDirectory(applicationSupport: $0))
        }
        let keeper = WrittenMarginDraftKeeper(
            journal: journal,
            currentDraft: { [weak self] in self?.writtenMarginDraft },
            onFailure: { [weak self] detail in self?.diagnostics["writtenMarginDraftJournal"] = detail }
        )
        marginCapture.draftKeeper = keeper
        return keeper
    }

    /// The listener typed: journal the latest text once typing pauses.
    func journalWrittenMarginText() {
        guard let draft = writtenMarginDraft else { return }
        writtenMarginDraftKeeper.textChanged(draft)
    }

    /// The Margin was saved or discarded: nothing is left to recover.
    func clearWrittenMarginJournal(captureId: String) {
        writtenMarginDraftKeeper.discard(captureId: captureId)
    }

    /// Launch: reopens the unfinished Margin that belongs to the restored session, with its text. A draft for a
    /// session that isn't open is left where it is. Returns what to tell the listener, or nil.
    func restoreUnfinishedWrittenMargin(store: SQLiteSessionStore) -> String? {
        guard let engine, writtenMarginDraft == nil,
              let support = try? applicationSupportDirectory() else { return nil }
        let journal = WrittenMarginDraftJournal(directory: WrittenMarginDraftJournal.standardDirectory(applicationSupport: support))
        do {
            let loaded = try journal.load()
            if !loaded.unreadableFileNames.isEmpty { diagnostics["writtenMarginDraftsUnreadable"] = "\(loaded.unreadableFileNames.count)" }
            guard let sessionId = engine.currentSession?.id,
                  let record = loaded.drafts.first(where: { $0.sessionId == sessionId }) else { return nil }
            let capture = try engine.restoreWrittenInterjection(record.capture)
            snapshot = engine.snapshot
            var draft = makeWrittenMarginDraft(for: capture, store: store, reply: nil)
            draft.text = record.text
            marginCapture.openDraft(draft)
            diagnostics["writtenMarginDraftRestored"] = capture.id
            return "Your unfinished Margin was kept."
        } catch {
            diagnostics["writtenMarginDraftRestore"] = "failed:\(error.localizedDescription)"
            return nil
        }
    }
}
