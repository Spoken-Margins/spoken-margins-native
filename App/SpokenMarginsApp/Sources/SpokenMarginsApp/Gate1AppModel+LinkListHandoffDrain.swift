import Foundation
import SessionKit

// Link lists the "Add Link List to Spoken Margins" Shortcuts action saved while the app was closed (#4683, Design
// section 2g). The action only writes `LinkListHandoffs/` in the App Group; the app adds them here, the next time it
// opens or comes forward, through the same arrival every other route uses. Kept out of Gate1AppModel.swift.
extension Gate1AppModel {
    /// The folder the Shortcuts action writes, beside the other handoffs in the same App Group (tests inject theirs
    /// through the source link handoff store).
    func resolvedLinkListHandoffFolder() throws -> LinkListHandoffFolder {
        LinkListHandoffFolder(baseDirectory: try resolvedSourceLinkHandoffStore().rootDirectory)
    }

    /// Adds every saved list, oldest first, awaiting each arrival before the next.
    ///
    /// - It stops at the first closed gate (another import is running) or when the phone is offline. Nothing is tried and
    ///   nothing is counted then; the files stay for the next foreground.
    /// - A file whose links all landed is removed. One that failed online is counted in `LinkListRetryLedger`, and is
    ///   removed on its third failed try, the arrival's banner being the last word.
    /// - A file that can't be read as a list is removed at once, with a banner.
    func drainLinkListHandoffs() async {
        // Two foregrounds in a row (or a Retry) can both get here; the second finds the first at work and leaves.
        guard !linkListArrival.isDrainingHandoffs else { return }
        linkListArrival.isDrainingHandoffs = true
        defer { linkListArrival.isDrainingHandoffs = false }

        let folder: LinkListHandoffFolder
        do { folder = try resolvedLinkListHandoffFolder() } catch {
            diagnostics["pendingLinkListHandoffs"] = "unavailable:\(SafeErrorText.describe(error))"
            return
        }
        // The folder is shared with the Shortcuts process, so reading it runs off the main actor.
        let entries = (try? await Self.offMain { folder.pending() }) ?? []
        diagnostics["pendingLinkListHandoffs"] = "\(entries.count)"
        // An empty listing can also be a folder that couldn't be listed this time; never wipe the counts on that.
        guard !entries.isEmpty else { return }
        linkListArrival.handoffRetry.prune(keeping: Set(entries.map(\.id)))
        guard !connectivity.isOffline else { return }
        // Checked once, right before the claim and with no suspension between them: the arrival holds
        // `sourceImportTask` for the whole drain, so its own run never blocks itself.
        guard !linkListArrivalIsBusy else { return }
        // The task frees the gate itself, as the Quick Folder's does, so no later import sees a finished task as busy.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.arriveHandoffLinkLists(entries, from: folder)
            self.sourceImportTask = nil
            // The Quick Folder's own refresh was put off while this held the gate; run it now, as every other import's end does.
            self.refreshQuickAccessFolder()
        }
        sourceImportTask = task
        await task.value
    }

    private func arriveHandoffLinkLists(_ entries: [LinkListHandoffFolder.Entry], from folder: LinkListHandoffFolder) async {
        let ledger = linkListArrival.handoffRetry
        var unreadable = 0
        for entry in entries {
            guard !Task.isCancelled else { break }
            // Failed online earlier this foreground: waits for the next one, so a share or a Retry can't spend its tries.
            guard !linkListArrival.isHandoffHeld(entry.id) else { continue }
            let recognition = (try? await Self.offMain { folder.read(entry) }) ?? .notALinkList
            guard case .linkList(let list) = recognition else {
                // Unreadable: removed at once, and the listener is told once.
                await Self.removeHandoffFile(entry, from: folder)
                ledger.clear(entry.id)
                unreadable += 1
                continue
            }
            let result = await runLinkListArrival(list, route: .handoffFolder)
            // Offline, or another import started meanwhile: nothing was tried and nothing is counted. This file and the
            // ones after it wait for the next foreground.
            guard result.attempted else { break }
            let tries = result.allLanded ? 0 : ledger.recordFailedTry(for: entry.id)
            switch LinkListArrivalPlan.handoffSettlement(
                attempted: result.attempted, allLanded: result.allLanded, triesAfterThisAttempt: tries) {
            case .remove:
                await Self.removeHandoffFile(entry, from: folder)
                ledger.clear(entry.id)
            case .keep:
                linkListArrival.holdHandoff(entry.id)
            }
        }
        // Told last, so the next file's banner can't cover it (the share drain's rule for a failure).
        if unreadable > 0 { reportFailure(LinkListArrivalPlan.unreadableHandoffMessage) }
    }

    private nonisolated static func removeHandoffFile(_ entry: LinkListHandoffFolder.Entry, from folder: LinkListHandoffFolder) async {
        _ = try? await offMain { folder.remove(entry) }
    }
}
