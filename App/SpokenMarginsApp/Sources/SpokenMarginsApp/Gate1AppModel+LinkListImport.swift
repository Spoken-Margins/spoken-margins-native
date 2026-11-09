import Foundation
import SessionKit

// Structured link lists picked from the Add sheet's Files route (#3767). Kept out of Gate1AppModel.swift.
extension Gate1AppModel {
    /// What a pick of `.json` files holds: link lists, files that said they were link lists but can't be taken (with
    /// the reason), and every other file, which goes to the Listening Edition import exactly as before.
    struct LinkListPick: Sendable {
        var lists: [(name: String, list: LinkListFile)] = []
        var rejections: [(name: String, message: String)] = []
        var others: [URL] = []
        var isEmpty: Bool { lists.isEmpty && rejections.isEmpty }
    }

    /// Reads each picked `.json` file off the main thread and sorts it by its own `schemaVersion` (never by name).
    /// A file that can't be read is left in `others`, so the edition import reports it the way it always did.
    func splitLinkLists(from urls: [URL]) async -> LinkListPick {
        await Task.detached(priority: .userInitiated) { Self.sortLinkListFiles(urls) }.value
    }

    private nonisolated static func sortLinkListFiles(_ urls: [URL]) -> LinkListPick {
        var pick = LinkListPick()
        for url in urls {
            guard let data = linkListFileData(url) else { pick.others.append(url); continue }
            switch LinkListFile.recognize(data) {
            case .notALinkList: pick.others.append(url)
            case .linkList(let list): pick.lists.append((url.lastPathComponent, list))
            case .rejected(let message): pick.rejections.append((url.lastPathComponent, message))
            }
        }
        return pick
    }

    /// The file's bytes, or nil when it can't be read or is too big to be a link list or an edition.
    private nonisolated static func linkListFileData(_ url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        // A file over the link-list limit may still be a Listening Edition (up to 8 MB), so it is read only to be
        // told apart from one; `recognize` refuses an oversized list on its own.
        guard size <= 8_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Adds each link, one at a time and in file order, the way a pasted link is added: the existing link import
    /// resolves podcast, article and PDF links, so there is no second resolver. Nothing starts playing. A link that
    /// can't be resolved is named and the rest still arrive. `message` is what to tell the listener when something did
    /// not go in; the sheet shows it under the Files button itself, because a later import's confirmation, or a
    /// banner that can't replace another, would otherwise lose it.
    @discardableResult
    func importLinkLists(_ pick: LinkListPick) async -> (allImported: Bool, message: String?) {
        var added = 0
        var failedLinks: [String] = []
        for (_, list) in pick.lists {
            for entry in list.entries {
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
