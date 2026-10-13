import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Quick Add candidates and the Quick Access folder (#970), moved unchanged out of the central model.
extension Gate1AppModel {
    var quickAddCandidates: [QuickAddCandidate] {
        if let cachedQuickAddCandidates { return cachedQuickAddCandidates }
        let candidates = Self.quickAddCandidates(
            folderFiles: quickAccessRecentFiles,
            followedEntries: followedSourceEntries,
            subscriptions: feedSubscriptions,
            libraryItems: libraryItems,
            dismissedFileKeys: dismissedQuickAccessFileKeys
        )
        cachedQuickAddCandidates = candidates
        return candidates
    }

    var isRefreshingQuickAddFeed: Bool {
        isRefreshingQuickAccessFolder || isRefreshingFollowedSources
    }

    func dismissQuickAccessFile(_ file: QuickAccessFile) { dismissedQuickAccessFileKeys.insert(file.dismissalKey) }

    /// Brings a dismissed Quick Folder file back into Following (#477).
    func restoreQuickAccessFile(_ file: QuickAccessFile) { dismissedQuickAccessFileKeys.remove(file.dismissalKey) }

    func configureQuickAccessFolder(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: quickAccessFolderBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "quickAccessFolderName")
            quickAccessFolderName = url.lastPathComponent
            refreshQuickAccessFolder()
            reportSuccess("Quick folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Quick folder setup failed")
        }
    }

    func refreshQuickAccessFolder() {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            quickAccessRefreshID = UUID()
            quickAccessRefreshTask?.cancel()
            quickAccessRefreshTask = nil
            isRefreshingQuickAccessFolder = false
            quickAccessRecentFiles = []
            return
        }
        let refreshID = UUID()
        quickAccessRefreshID = refreshID
        quickAccessRefreshTask?.cancel()
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        isRefreshingQuickAccessFolder = true
        quickAccessRefreshTask = Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                Self.scanQuickAccessFolder(folderURL)
            }.value
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
            guard let self, self.quickAccessRefreshID == refreshID else { return }
            self.quickAccessRefreshTask = nil
            self.isRefreshingQuickAccessFolder = false
            if let errorDescription = scan.errorDescription {
                self.quickAccessRecentFiles = []
                self.diagnostics["quickAccessError"] = errorDescription
                return
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            self.quickAccessRecentFiles = scan.files.map { entry in
                QuickAccessFile(
                    id: entry.id,
                    name: entry.name,
                    relativePath: entry.relativePath,
                    modifiedAt: entry.modifiedAt,
                    modifiedAtDescription: formatter.localizedString(for: entry.modifiedAt, relativeTo: Date())
                )
            }
            self.quickAccessFolderName = folderURL.lastPathComponent
            self.diagnostics["quickAccessFolder"] = folderURL.lastPathComponent
            self.diagnostics["quickAccessRecentFiles"] = "\(self.quickAccessRecentFiles.count)"
        }
    }

    func importQuickAccessFile(_ file: QuickAccessFile, openWhenFinished: Bool = false) {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        let fileURL = folderURL.appending(path: file.relativePath)
        beginObsidianMarkdownImport(
            urls: [fileURL],
            securityScopedURLs: [folderURL],
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
