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

    /// Undo (Design 2.7). The order, live side first and item rows last so a Margin is never in neither place, is
    /// `LiveMarginMove.undo`'s; this runs it off the main thread and tells the app.
    static func undo(plan: LiveMarginMove.Plan, moved: [Interjection], model: Gate1AppModel, files: LiveSessionFileWorker = .shared) async {
        guard let store = model.store else { return }
        // A second tap on the same banner's Undo: the first already put them back.
        if !moved.isEmpty, moved.allSatisfy({ wasTakenBack($0.id) }) { return }
        let outcome = await Task.detached(priority: .userInitiated) {
            await LiveMarginMove.undo(plan: plan, moved: moved, repository: store, files: files)
        }.value
        switch outcome {
        case let .putBack(count):
            takenBackIds.formUnion(moved.map(\.id))
            model.liveMarginsTakenBack(itemId: plan.itemId)
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            model.reportConfirmation(LiveMarginMove.Wording.putBack(count: count))
            await LiveSessionSpokenMargins.transcribeMissing()
        case let .refused(refusal):
            model.reportFailure(refusal.message)
        case .failed:
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            model.reportFailure(LiveMarginMove.Wording.putBackFailed(title: plan.itemTitle))
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
