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

    /// Adds the links of each listed Quick Folder file through the same link import as `+ > Files`, one file at a
    /// time and in order. One import runs at a time, like the text import. A file that can't be read as a link list (it
    /// changed after the scan, or is still syncing) is named, never sent to the edition import or read as text. A file whose links all
    /// arrived leaves the Quick Add list; one that did not stays, so the listener can try again (a link already
    /// added is recognised by the link import's own same-address check).
    func importQuickFolderLinkLists(_ files: [QuickAccessFile], folderURL: URL) {
        guard !files.isEmpty else { return }
        guard sourceImportTask == nil else {
            reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            return
        }
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        sourceImportProgressMessage = files.count == 1 ? "Reading \(files[0].relativePath)…" : "Reading \(files.count) link lists…"
        statusMessage = sourceImportProgressMessage ?? "Reading link lists…"
        lastError = nil
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
                let result = await self.importLinkLists(pick)
                guard result.allImported else { continue }
                self.hangTelemetry.labels.scoped("quickFolderLinkListFinish") { self.dismissQuickAccessFile(file) }
            }
            self.sourceImportTask = nil
            self.sourceImportProgressMessage = nil
            self.refreshQuickAccessFolder()
        }
    }
}
