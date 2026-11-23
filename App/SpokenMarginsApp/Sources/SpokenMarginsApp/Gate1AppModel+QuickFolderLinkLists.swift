import Foundation
import SessionKit

// Structured link lists found in the Quick Folder (#3767). The scan only offers a `.json` file that says it is a link
// list (`QuickAccessFolderScanner`), so a `.json` file in the Quick Add list is one. Kept out of Gate1AppModel.swift.
extension Gate1AppModel {
    /// True for a Quick Folder file that is a link list. The scan admits a `.json` file only when its own
    /// `schemaVersion` says so, so the extension here is a routing tag, never a test of what the file holds.
    nonisolated static func isQuickFolderLinkList(_ file: QuickAccessFile) -> Bool {
        (file.relativePath as NSString).pathExtension.lowercased() == "json"
    }

    /// Brings each listed Quick Folder file in through the link list arrival (#4683), one file at a time and in order: a
    /// titled list becomes a collection, an untitled one loose items, its follow entries wait as suggestions, and nothing
    /// starts playing. One import runs at a time, like the text import. A file that can't be read as a link list (it
    /// changed after the scan, or is still syncing) is named, never sent to the edition import or read as text.
    ///
    /// A file whose links all arrived leaves the Quick Add list. One that did not stays. When it didn't land while the
    /// phone was online, the failure is counted (`LinkListRetryLedger`) and the next refresh tries it again, up to three
    /// tries; then it waits in Quick Add for a tap. Offline, nothing is tried and nothing is counted. A link already
    /// added is recognised by the link import's own same-address check, and the list's key makes a retry fill the same
    /// collection.
    func importQuickFolderLinkLists(_ files: [QuickAccessFile], folderURL: URL, automatic: Bool = false) {
        guard !files.isEmpty else { return }
        guard !linkListArrivalIsBusy else {
            // On its own, the file is tried again at the next refresh (the other import ends with one); tapped, the listener is told.
            if automatic { releaseAutomaticQuickFolderFiles(files, holdUntilForeground: false) } else {
                reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            }
            return
        }
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        sourceImportProgressMessage = files.count == 1 ? "Reading \(files[0].relativePath)…" : "Reading \(files.count) link lists…"
        statusMessage = sourceImportProgressMessage ?? "Reading link lists…"
        lastError = nil
        let route: LinkListArrivalPlan.Route = automatic ? .quickFolderAutomatic : .quickFolderTapped
        sourceImportTask = Task { [weak self] in
            defer { if didAccess { folderURL.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            // One file at a time, so a file whose links all arrived leaves Quick Add even when a later file had a bad link.
            for file in files {
                guard !Task.isCancelled else { break }
                let pick = await self.splitLinkLists(from: [folderURL.appending(path: file.relativePath)])
                if !pick.others.isEmpty {
                    // Unreadable (still syncing or being written) or changed since the scan: never sent to the edition import or read as text.
                    self.reportFailure("\(file.relativePath) could not be read as a link list, so nothing was added from it.")
                    continue
                }
                if let rejection = pick.rejections.first {
                    self.reportFailure("\(rejection.name): \(rejection.message)")
                    continue
                }
                guard let found = pick.lists.first else { continue }
                let result = await self.runLinkListArrival(found.list, route: route, quickFolderFileID: file.id)
                self.settleQuickFolderLinkList(file, result: result, automatic: automatic)
            }
            self.sourceImportTask = nil
            self.sourceImportProgressMessage = nil
            self.refreshQuickAccessFolder()
        }
    }

    /// What happens to a Quick Folder file once its arrival has run (2g): it leaves Quick Add when every link landed;
    /// otherwise it waits for another try, or stays for a tap.
    private func settleQuickFolderLinkList(_ file: QuickAccessFile, result: LinkListArrivalResult, automatic: Bool) {
        let ledger = linkListArrival.quickFolderRetry
        guard result.attempted else {
            // Offline, or another import started meanwhile: no try is counted. On its own the file is looked at again when
            // the app next comes forward (offline) or at the next refresh (busy); a tap is told why nothing happened.
            if automatic {
                releaseAutomaticQuickFolderFiles([file], holdUntilForeground: result.notTried == .offline)
            } else {
                reportFailure(result.notTried == .busy
                    ? Self.collectionImportBusyMessage
                    : "You're offline. Try \(file.name) again when you're connected.")
            }
            return
        }
        let tries = result.allLanded ? 0 : ledger.recordFailedTry(for: file.id)
        switch LinkListArrivalPlan.settlement(allLanded: result.allLanded, triesAfterThisAttempt: tries) {
        case .done:
            ledger.clear(file.id)
            hangTelemetry.labels.scoped("quickFolderLinkListFinish") { self.dismissQuickAccessFile(file) }
        case .retryLater:
            if automatic { releaseAutomaticQuickFolderFiles([file], holdUntilForeground: true) }
        case .stayForTap:
            // It stays in the Quick Add list for a tap, as a list that never landed always has.
            break
        }
    }

    /// Takes automatic Quick Folder files back out of the seen set, so the next refresh tries them again. With
    /// `holdUntilForeground`, they also wait until the app next comes forward, so the refresh that ends this import
    /// doesn't start the next try at once and spend all three tries in a few seconds.
    private func releaseAutomaticQuickFolderFiles(_ files: [QuickAccessFile], holdUntilForeground: Bool) {
        if holdUntilForeground { for file in files { linkListArrival.hold(file.id) } }
        quickAccess.inboxSeenFileIds = quickAccess.inboxSeenFileIds?.subtracting(files.map(\.id))
    }
}
