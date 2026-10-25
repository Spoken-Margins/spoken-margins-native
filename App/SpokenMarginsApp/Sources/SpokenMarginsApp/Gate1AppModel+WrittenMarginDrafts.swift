import Foundation
import SessionKit
import SessionKitPersistence

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

    /// A draft for an item that is gone can never be reopened, so it is removed. Every other draft stays until its
    /// Margin is saved or discarded, however long ago it was typed.
    private func discardAbandonedWrittenMarginDrafts(_ drafts: [WrittenMarginDraftRecord], journal: WrittenMarginDraftJournal, store: SQLiteSessionStore) -> [WrittenMarginDraftRecord] {
        drafts.filter { draft in
            guard (try? store.loadItem(id: draft.itemId)) == nil else { return true }
            try? journal.remove(id: draft.id)
            return false
        }
    }

    /// Launch: reopens an unfinished Margin with its text, whatever state its item was left in. The draft that
    /// belongs to the restored session wins; otherwise the newest one does, and its session is opened for it (a
    /// source played to the end is not "in progress", so nothing else would bring the listener back to it).
    /// Only items still in the Library qualify, as for the restored session itself. A draft that can't be opened
    /// is skipped, never half-opened: everything that can fail runs before any state changes. Returns what to
    /// tell the listener, or nil.
    func restoreUnfinishedWrittenMargin(store: SQLiteSessionStore, availableItemIDs: Set<String>) -> String? {
        guard let engine, writtenMarginDraft == nil,
              let support = try? applicationSupportDirectory() else { return nil }
        let journal = WrittenMarginDraftJournal(directory: WrittenMarginDraftJournal.standardDirectory(applicationSupport: support))
        let loaded: WrittenMarginDraftJournal.Loaded
        do { loaded = try journal.load() } catch {
            diagnostics["writtenMarginDraftRestore"] = "failed:\(error.localizedDescription)"
            return nil
        }
        if !loaded.unreadableFileNames.isEmpty { diagnostics["writtenMarginDraftsUnreadable"] = "\(loaded.unreadableFileNames.count)" }
        let drafts = discardAbandonedWrittenMarginDrafts(loaded.drafts, journal: journal, store: store)
        let restoredSessionId = engine.currentSession?.id
        let candidates = WrittenMarginDraftJournal.restoreOrder(drafts, restoredSessionId: restoredSessionId)
            .filter { availableItemIDs.contains($0.itemId) }
        for record in candidates {
            do {
                if record.sessionId != restoredSessionId {
                    guard try store.loadSessions().contains(where: { $0.id == record.sessionId }) else { continue }
                    let detail = try loadItemDetail(id: record.itemId, store: store)
                    snapshot = try engine.inspectSession(sessionId: record.sessionId)
                    activeItemId = record.itemId
                    selectedItem = detail
                    // The draft only needs the session open. A source whose file is gone reports that when played.
                    do { try prepareSourceMediaPlayback(itemId: record.itemId) } catch {
                        diagnostics["writtenMarginDraftSource"] = "unavailable:\(error.localizedDescription)"
                    }
                }
                let capture = try engine.restoreWrittenInterjection(record.capture)
                snapshot = engine.snapshot
                var draft = makeWrittenMarginDraft(for: capture, store: store, replyChoice: MarginReplyChoice())
                draft.text = record.text
                marginCapture.openDraft(draft)
                diagnostics["writtenMarginDraftRestored"] = capture.id
                return "Your unfinished Margin was kept."
            } catch {
                diagnostics["writtenMarginDraftRestore"] = "failed:\(error.localizedDescription)"
            }
        }
        return nil
    }
}
