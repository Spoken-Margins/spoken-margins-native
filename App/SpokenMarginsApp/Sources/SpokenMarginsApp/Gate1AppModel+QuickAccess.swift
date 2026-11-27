import Foundation
import SessionKit

/// Quick Add candidates and the Quick Access folder (#970, #981). The folder's state and logic live in
/// `QuickAccessFolderState`; these are the model's forwarders and the parts that need the model.
extension Gate1AppModel {
    var quickAccessFolderName: String { quickAccess.folderName }
    var quickAccessRecentFiles: [QuickAccessFile] { quickAccess.recentFiles }

    var quickAddCandidates: [QuickAddCandidate] {
        quickAccess.candidates(
            followedEntries: followedSourceEntries,
            subscriptions: feedSubscriptions,
            libraryItems: libraryItems
        )
    }

    nonisolated static func quickAddCandidates(
        folderFiles: [QuickAccessFile],
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription] = [],
        libraryItems: [LibraryItemRow] = [],
        dismissedFileKeys: Set<String> = []
    ) -> [QuickAddCandidate] {
        QuickAccessFolderState.candidates(
            folderFiles: folderFiles,
            followedEntries: followedEntries,
            subscriptions: subscriptions,
            libraryItems: libraryItems,
            dismissedFileKeys: dismissedFileKeys
        )
    }

    /// Connects the folder state to the model at launch: change forwarding and diagnostics.
    func wireQuickAccessFolder() {
        quickAccess.forwardWillChange(to: objectWillChange)
        quickAccess.recordDiagnostic = { [weak self] key, value in self?.diagnostics[key] = value }
    }

    func dismissQuickAccessFile(_ file: QuickAccessFile) { quickAccess.dismiss(file) }

    /// Brings a dismissed Quick Folder file back into Following (#477).
    func restoreQuickAccessFile(_ file: QuickAccessFile) { quickAccess.restore(file) }

    /// The Add sheet's and Settings' Choose Folder: entry 1, or the first folder when none is chosen.
    func configureQuickAccessFolder(url: URL) {
        chooseQuickFolder(url) { try quickAccess.configure(url: url, whenSaved: $0) }
    }

    /// A folder's own Change Folder (#3770 Design PR 5).
    func configureQuickAccessFolder(url: URL, folder folderID: QuickFolderList.Entry.ID) {
        chooseQuickFolder(url) { try quickAccess.configure(url: url, folder: folderID, whenSaved: $0) }
    }

    /// Settings' "Choose Folder Again" (#3770): the same folder keeps what the last scan learned and its dismissed files;
    /// any other folder is a fresh baseline, as `configureQuickAccessFolder`. The confirmation is the same.
    func reconnectQuickAccessFolder(url: URL) {
        chooseQuickFolder(url) { _ = try quickAccess.reconnect(url: url, whenSaved: $0) }
    }

    /// "Choose Folder Again" on one folder's screen.
    func reconnectQuickAccessFolder(url: URL, folder folderID: QuickFolderList.Entry.ID) {
        chooseQuickFolder(url) { _ = try quickAccess.reconnect(url: url, folder: folderID, whenSaved: $0) }
    }

    /// "Add Another Folder" in Settings and the Add sheet (#3770 Design PR 5). The same folder twice is refused with
    /// "That folder is already a Quick Folder."
    func addQuickAccessFolder(url: URL) {
        chooseQuickFolder(url) { try quickAccess.add(url: url, whenSaved: $0) }
    }

    /// Runs one way of choosing a folder with the confirmation every one of them gives ("Quick folder set to X.", kept as it is,
    /// Design Default 10), and says plainly when the folder is refused.
    private func chooseQuickFolder(_ url: URL, _ choose: (() -> Void) throws -> Void) {
        do {
            try choose { reportSuccess("Quick folder set to \(url.lastPathComponent).") }
        } catch let refused as QuickAccessFolderState.ChoiceError {
            reportFailure(refused.message)
        } catch {
            reportFailure(error, context: "Quick folder setup failed")
        }
    }

    /// Settings' "Remove Folder" (#3770) for entry 1. Nothing in the Library or the play queue is touched.
    func removeQuickAccessFolder() { quickAccess.remove() }

    /// "Remove Folder" on one folder's screen.
    func removeQuickAccessFolder(_ folderID: QuickFolderList.Entry.ID) { quickAccess.remove(folderID) }

    /// Rescans every Quick Folder.
    func refreshQuickAccessFolder() { quickAccess.refresh() }

    /// "Check Now" on one folder's screen.
    func refreshQuickAccessFolder(_ folderID: QuickFolderList.Entry.ID) { quickAccess.refresh(folderID) }

    func importQuickAccessFile(_ file: QuickAccessFile, openWhenFinished: Bool = false) {
        guard let urls = quickAccess.importURLs(for: file) else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        // A `.json` file in the Quick Folder is a structured link list: its links are added, it is never read as text (#3767).
        if Self.isQuickFolderLinkList(file) {
            importQuickFolderLinkLists([file], folderURL: urls.folderURL)
            return
        }
        // A `.txt` that reads as a meeting transcript becomes a transcript item; anything else imports as before (#2997).
        importFilesWithTranscriptRule(
            urls: [urls.fileURL],
            route: TranscriptPickRoute(
                securityScopedURLs: [urls.folderURL],
                refreshQuickFolderWhenFinished: true,
                openImportedItemWhenFinished: openWhenFinished,
                quickAccessFileToDismiss: file))
    }

    func refreshQuickAddFeed(force: Bool = true, trigger: FollowedRefreshTrigger) {
        // Coming forward is when a link list that waited offline or failed is tried again (#4683).
        if trigger == .foreground { linkListArrival.releaseHeldFiles() }
        refreshQuickAccessFolder()
        refreshFollowedSources(force: force, trigger: trigger)
    }

    /// Pull-down refresh on Following (#1438), its only manual refresh since #4955. It is awaited so the spinner stays until
    /// the feeds are read. The refresh runs in its own task, so SwiftUI cancelling the gesture's task when the list redraws
    /// can't cut it short. A pull while a refresh runs starts no second pass: that pass goes round once more, and the pull
    /// waits for it to end (#4955).
    func pullToRefreshFollowing() async {
        refreshQuickAccessFolder()
        replyBoxes.pullToRefresh() // answers through share links (#4675); never holds the spinner
        await Task { [self] in
            // The gate refuses only while a pass runs, and the flag goes true with no await after the gate accepts, so a nil
            // with the flag set means a running pass took this request; a nil from a store that couldn't open comes after
            // the pass's `defer` cleared the flag, so the pull returns at once.
            if await self.performFollowedSourceRefresh(force: true, trigger: .pull) == nil, self.isRefreshingFollowedSources {
                await self.followedSourcePassEnd.waitForEnd()
            }
        }.value
    }
}
