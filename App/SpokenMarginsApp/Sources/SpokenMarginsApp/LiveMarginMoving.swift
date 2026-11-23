import Foundation
import SessionKit
import SessionKitPersistence

/// Runs a move of live-session Margins onto an item, and its Undo, in the order the Design sets (#4233 Design 2.9.4): the
/// item side in one transaction off the main thread, then the live side on the file worker, then the screens. The rules
/// and the writes are SessionKit's (`LiveMarginMove`, `LiveSessionFileWorker`); this only sequences them and tells the
/// app. Undo lives here and not on the sheet, because the sheet has closed by the time the banner's Undo is tapped.
@MainActor
enum LiveMarginMoving {
    /// Ids of moved Margins whose item rows an Undo removed this launch. A transcription that finishes after that ends
    /// quietly instead of reporting a failure on a row that is gone (Design 2.9.2).
    private static var takenBackIds: Set<String> = []

    static func wasTakenBack(_ interjectionId: String) -> Bool { takenBackIds.contains(interjectionId) }

    /// What a finished move tells the screen that started it.
    struct Moved {
        let plan: LiveMarginMove.Plan
        let moved: [Interjection]
        /// True when the move emptied and removed the live session: its screen closes.
        let removedSession: Bool
    }

    /// The move's plan, read against the session as it is now on disk (a Watch delete or a discard may have taken some of
    /// the chosen Margins meanwhile), off the main thread.
    static func plan(
        margins: [LiveSessionMargin], sessionId: String, itemId: String,
        model: Gate1AppModel, files: LiveSessionFileWorker = .shared
    ) async throws -> LiveMarginMove.Plan {
        let store = try model.requireStore()
        guard let current = await files.session(id: sessionId) else { throw LiveMarginMove.Failure.nothingToMove }
        let runs = PlayerRunController.runs()
        return try await StoreReader(store).read(priority: .userInitiated) {
            try LiveMarginMove.plan(margins: margins, session: current, itemId: itemId, runs: runs, repository: $0)
        }
    }

    /// Moves the Margins. Nil when the item side couldn't be written: then nothing changed anywhere. Once the item side is
    /// written the move counts as done even if the live side's write fails, because the next launch finishes it
    /// (`reconcileAtLaunch`), so a Margin is never shown in both places for longer than that.
    static func move(_ plan: LiveMarginMove.Plan, model: Gate1AppModel, files: LiveSessionFileWorker = .shared) async -> Moved? {
        guard let store = model.store else { return nil }
        let moved: [Interjection]
        do {
            moved = try await Task.detached(priority: .userInitiated) {
                try LiveMarginMove.execute(plan: plan, repository: store)
            }.value
        } catch {
            model.recordDeveloperDiagnostic("liveMarginMove.failed", ["error": SafeErrorText.describe(error)])
            return nil
        }
        takenBackIds.subtract(moved.map(\.id))
        let removal = try? await files.removeMovedMargins(ids: plan.liveMarginIds, fromSession: plan.session.id)
        NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
        model.liveMarginsMoved(moved)
        model.presentLiveMarginMoveUndo(count: moved.count, title: plan.itemTitle) {
            Task { await undo(plan: plan, moved: moved, model: model, files: files) }
        }
        return Moved(plan: plan, moved: moved, removedSession: removal?.removedSession ?? plan.removesSession)
    }

    /// Undo (Design 2.7): refused, with nothing changed, when the session was discarded or saved as notes meanwhile, or the
    /// listener changed a moved Margin on the item. Otherwise the item rows go, and the live Margins come back with any
    /// words a transcription found meanwhile.
    static func undo(plan: LiveMarginMove.Plan, moved: [Interjection], model: Gate1AppModel, files: LiveSessionFileWorker = .shared) async {
        guard let store = model.store else { return }
        // A second tap on the same banner's Undo: the first already put them back.
        if !moved.isEmpty, moved.allSatisfy({ wasTakenBack($0.id) }) { return }
        if await files.currentDeletions().deletedSession(plan.session.id) {
            return model.reportFailure(LiveMarginMove.UndoRefusal.discarded.message)
        }
        if await files.session(id: plan.session.id)?.savedItemId != nil {
            return model.reportFailure(LiveMarginMove.UndoRefusal.savedAsNotes.message)
        }
        let words: [String: String]?
        do {
            words = try await Task.detached(priority: .userInitiated) { () throws -> [String: String]? in
                guard !LiveMarginMove.listenerChanged(moved, repository: store) else { return nil }
                return try LiveMarginMove.undoItemSide(moved, repository: store)
            }.value
        } catch {
            return model.reportFailure(error, context: "Couldn't put the Margins back")
        }
        guard let words else { return model.reportFailure(LiveMarginMove.UndoRefusal.changedOnItem(title: plan.itemTitle).message) }
        takenBackIds.formUnion(moved.map(\.id))
        let margins = plan.margins.map { planned -> LiveSessionMargin in
            var margin = planned.margin
            if margin.isSpoken, margin.spokenTranscript == nil, let found = words[margin.id] { margin.text = found }
            return margin
        }
        let outcome: LiveSessionFileWorker.RestoreOutcome
        do {
            outcome = try await files.restoreMovedMargins(margins, into: plan.session)
        } catch {
            return model.reportFailure(error, context: "Couldn't put the Margins back")
        }
        model.liveMarginsTakenBack(itemId: plan.itemId)
        switch outcome {
        case .restored:
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            model.reportConfirmation(LiveMarginMove.Wording.putBack(count: margins.count))
            await LiveSessionSpokenMargins.transcribeMissing()
        case .savedAsNotes:
            model.reportFailure(LiveMarginMove.UndoRefusal.savedAsNotes.message)
        case .discarded:
            model.reportFailure(LiveMarginMove.UndoRefusal.discarded.message)
        }
    }

    /// Finishes a move the app was stopped in the middle of (Design 2.9.4 step 3): once both stores are open, and before
    /// the Watch inbox is filed, any live Margin whose moved copy is active on an item leaves its session.
    /// False when the item side couldn't be read, so the caller tries again on its next pass.
    @discardableResult
    static func reconcileAtLaunch(store: SQLiteSessionStore, files: LiveSessionFileWorker = .shared) async -> Bool {
        guard let origins = try? await StoreReader(store).read(priority: .utility, { try $0.loadMovedMarginOrigins() }) else {
            return false
        }
        let liveIds = origins.map(\.liveMarginId)
        guard !liveIds.isEmpty else { return true }
        let touched = await files.reconcileMovedMargins(liveMarginIds: Set(liveIds))
        if !touched.isEmpty { NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil) }
        return true
    }
}
