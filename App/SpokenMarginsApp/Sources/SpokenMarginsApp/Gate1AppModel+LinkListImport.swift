import Foundation
import SessionKit

// Structured link lists picked from the Add sheet's Files route (#3767). Kept out of Gate1AppModel.swift.
extension Gate1AppModel {
    /// Reads each picked `.json` file, and the `.json` files in each picked folder, off the main thread and sorts them
    /// by their own `schemaVersion` (never by name or folder). A file that can't be read is left in `others`, so the
    /// edition import reports it the way it always did.
    func splitLinkLists(from urls: [URL], folders: [URL] = []) async -> LinkListPick {
        await Task.detached(priority: .userInitiated) { LinkListPick.sort(files: urls, folders: folders) }.value
    }

    /// Adds each link, one at a time and in file order, the way a pasted link is added: the existing link import
    /// resolves podcast, article and PDF links, so there is no second resolver. Nothing starts playing. A link that
    /// can't be resolved is named and the rest still arrive. `message` is what to tell the listener when something did
    /// not go in; the sheet shows it under the Files button itself, because a later import's confirmation, or a
    /// banner that can't replace another, would otherwise lose it.
    @discardableResult
    func importLinkLists(_ pick: LinkListPick, noteFolderTruncation: Bool = false) async -> (allImported: Bool, message: String?) {
        var added = 0
        var failedLinks: [String] = []
        for found in pick.lists {
            for entry in found.list.entries {
                if await importSourceLinkAsync(urlString: entry.url, sourceSurface: "link_list", startSession: false) {
                    added += 1
                } else {
                    failedLinks.append(entry.url)
                }
            }
        }
        let skipped = pick.lists.flatMap(\.list.skipped)
        var problems: [String] = pick.rejections.map { "\($0.name): \($0.message)" }
        if !failedLinks.isEmpty {
            let named = failedLinks.prefix(3).joined(separator: ", ")
            let more = failedLinks.count > 3 ? " and \(failedLinks.count - 3) more" : ""
            problems.append("Could not add \(named)\(more).")
        }
        if let note = LinkListFile.skippedNote(skipped) { problems.append(note) }
        // The edition import says this itself when it runs; when a folder held only link lists it does not run.
        if noteFolderTruncation, pick.folderTruncated { problems.append(ListeningEditionFolderWalk.truncationNote()) }
        if added > 0 { markOnboardingSteps([.addedOwnSource, .addedFromFiles]) }
        let summary = added == 0 ? "" : "Added \(added) \(added == 1 ? "link" : "links") from your list."
        if problems.isEmpty {
            reportConfirmation(summary)
            return (true, nil)
        }
        let message = ([summary] + problems).filter { !$0.isEmpty }.joined(separator: " ")
        if added > 0 { reportWarning(message) } else { reportFailure(message) }
        // Skipped entries alone (not https, no url) are named in the banner and still close the sheet.
        let allImported = added > 0 && failedLinks.isEmpty && pick.rejections.isEmpty
        return (allImported, allImported ? nil : message)
    }
}
