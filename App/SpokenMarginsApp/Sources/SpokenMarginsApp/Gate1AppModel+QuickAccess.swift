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

    var isRefreshingQuickAddFeed: Bool {
        quickAccess.isRefreshing || isRefreshingFollowedSources
    }

    func dismissQuickAccessFile(_ file: QuickAccessFile) { quickAccess.dismiss(file) }

    /// Brings a dismissed Quick Folder file back into Following (#477).
    func restoreQuickAccessFile(_ file: QuickAccessFile) { quickAccess.restore(file) }

    func configureQuickAccessFolder(url: URL) {
        do {
            try quickAccess.configure(url: url) {
                reportSuccess("Quick folder set to \(url.lastPathComponent).")
            }
        } catch {
            reportFailure(error, context: "Quick folder setup failed")
        }
    }

    func refreshQuickAccessFolder() { quickAccess.refresh() }

    func importQuickAccessFile(_ file: QuickAccessFile, openWhenFinished: Bool = false) {
        guard let urls = quickAccess.importURLs(for: file) else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        beginObsidianMarkdownImport(
            urls: [urls.fileURL],
            securityScopedURLs: [urls.folderURL],
            refreshQuickFolderWhenFinished: true,
            openImportedItemWhenFinished: openWhenFinished,
            quickAccessFileToDismiss: file
        )
    }

    func refreshQuickAddFeed(force: Bool = true) {
        refreshQuickAccessFolder()
        refreshFollowedSources(force: force)
    }
}
