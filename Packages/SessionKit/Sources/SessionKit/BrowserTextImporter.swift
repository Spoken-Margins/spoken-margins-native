#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Where a re-imported PDF's move to the new extraction (C1 M3 step 5) is planned and written.
enum StructuredUpgradeMode: Sendable {
    /// Here and now, as the synchronous imports do.
    case inline
    /// Hand it back as an `upgradeCandidate` for the caller to run off the main actor.
    case deferred
    /// Don't try; the new text becomes its own edition.
    case skip
}

enum BrowserTextImportOutcome: Sendable {
    case records(Item, ListeningMap?, StructuredDocument?, persisted: Bool = false)
    case upgradeCandidate(StructuredUpgradeJob)
}

/// Everything the upgrade needs, and nothing of the engine's, so the plan can run on any thread. The store is
/// `Sendable` (SQLite serializes on its connection lock), and the rest is values.
struct StructuredUpgradeJob: Sendable {
    let repository: any (SessionRepository & StructuredDocumentRepository)
    let existing: Item
    let document: StructuredDocument

    func plan() throws -> Result<StructuredDocumentUpgrade, StructuredDocumentUpgrader.StaysBecause> {
        try StructuredDocumentUpgrader.plan(
            existing: existing,
            document: document,
            listeningMap: StructuredDocumentImport.listeningMap(for: document, title: existing.title, itemId: existing.id),
            repository: repository
        )
    }

    func apply(_ upgrade: StructuredDocumentUpgrade) throws {
        try repository.applyStructuredDocumentUpgrade(upgrade)
    }
}

/// The part of a browser-text import that reads and writes the store, kept apart from the engine so the whole of it
/// can run off the main actor (#2509). It holds the store and two values the engine reads at the start: which items
/// the listener has open, and whether playback is running. Nothing in it touches the engine.
struct BrowserTextImporter: Sendable {
    let repository: any SessionRepository
    /// The ids of the item and session the engine holds open. A held item is never rewritten in place.
    let openItemIds: Set<String>
    let isPlaybackActive: Bool

    func outcome(
        _ handoff: BrowserTextHandoff,
        structuredDocument: StructuredDocument? = nil,
        upgrade mode: StructuredUpgradeMode
    ) throws -> BrowserTextImportOutcome {
        let fallbackTitle = cleanedBrowserTextTitle(handoff.source.title, url: handoff.source.url)
        let sourceExtension = URL(string: handoff.source.url)?.pathExtension.lowercased()
        // A v2 document only comes from a PDF, whatever its URL looks like
        // (https://arxiv.org/pdf/2607.28282v1 has no ".pdf").
        let isPDF = handoff.captureMode == .markdownFile && (sourceExtension == "pdf" || structuredDocument != nil)
        // A v2 PDF's canonical text is the document's; it isn't parsed as Markdown,
        // so every I13 range indexes Item.text exactly.
        let document = isPDF ? structuredDocument.flatMap { $0.text.isEmpty ? nil : $0 } : nil
        let rawText = (document?.text ?? handoff.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            throw SessionKitError.invalidCommandForState("importBrowserText")
        }

        let parsedMarkdown: ParsedObsidianMarkdown?
        if document == nil, handoff.contentFormat == .markdown {
            parsedMarkdown = try? ObsidianMarkdownParser.parse(fileName: fallbackTitle, contents: rawText, fallbackTitle: fallbackTitle)
        } else {
            parsedMarkdown = nil
        }
        let title = parsedMarkdown?.title ?? fallbackTitle
        // The id keeps the title this importer gave before page titles stopped being read as file
        // names (#1059), so a page already in the Library is found again on re-import.
        let idTitle = parsedMarkdown.map { $0.titleIsFallback ? ObsidianMarkdownParser.fileNameTitle(fallbackTitle) : $0.title } ?? fallbackTitle
        // A front-matter title or a title heading beats the page title. Body sections do not.
        // Resolve the display title separately from the legacy title used for item identity (#885).
        let titleCameFromPage = document == nil && (parsedMarkdown?.titleIsFallback ?? true)
        let postTitle = titleCameFromPage
            ? BrowserTextTitle.postTitle(pageTitle: fallbackTitle, url: handoff.source.url)
            : nil
        let displayTitle = postTitle ?? title
        let text = document?.text ?? (parsedMarkdown?.text ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("importBrowserText")
        }
        var itemId = handoff.itemId ?? browserTextItemId(title: idTitle, url: handoff.source.url)
        // A web or share-sheet PDF's id is a slug of its title and address. When a better title is read from
        // the same PDF (#2062), re-importing it must still find the item it already made (#556).
        var matchedByAddress = false
        if handoff.itemId == nil, isPDF, try existingItem(id: itemId) == nil,
           let sameAddress = try existingPDFItemId(atHTTPSAddress: handoff.source.url) {
            itemId = sameAddress
            matchedByAddress = true
        }
        if handoff.itemId == nil, handoff.captureMode == .readablePage || isPDF {
            // A corrected extraction (or a new PDF extractor) must not move existing
            // Margin anchors. Retain the original edition and give changed text its
            // own identity.
            if let existing = try existingItem(id: itemId), existing.text != text ||
                (document.map({ (try? (repository as? any StructuredDocumentRepository)?.loadStructuredDocument(itemId: itemId)) != $0 }) == true
                 && !(existing.text == text && openItemIds.contains(existing.id)
                      && !isPlaybackActive && existing.media?.sourceType != .generatedTTSPrerendered)) {
                // C1 M3 step 5: a PDF re-imported with a newer extraction moves the
                // existing item to it when every Margin and position lands on the same
                // words (I13 rule 1d). Otherwise it stays, and the new text becomes
                // its own edition as before. An item found only by its address may be a different PDF now
                // served there (a newsletter's "current.pdf"), so its text is never replaced in place.
                if mode != .skip, !matchedByAddress, let document, existing.deletedAt == nil, !openItemIds.contains(existing.id),
                   let store = repository as? any (SessionRepository & StructuredDocumentRepository) {
                    let job = StructuredUpgradeJob(repository: store, existing: existing, document: document)
                    if mode == .deferred { return .upgradeCandidate(job) }
                    if case .success(let upgrade)? = try? job.plan() {
                        do {
                            try job.apply(upgrade)
                            return .records(upgrade.item, upgrade.listeningMap, document, persisted: true)
                        } catch StructuredDocumentUpgradeError.changedSincePlanned {}
                    }
                }
                // Unchanged text has nothing to move: unless the open reader is playing or holds
                // prerendered narration, the one row takes the new document below, which also
                // brings a deleted paper back and keeps imported Margins on a single item.
                let heldReader = openItemIds.contains(existing.id)
                if existing.text != text || heldReader {
                    let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                    itemId += "-edition-\(digest)"
                }
            }
            if var existing = try existingItem(id: itemId) {
                // Repair an old automatic title on re-import, retaining the item and its anchors.
                // Match both raw and legacy filename titles, even if the capture format changed.
                // A title the listener changed to something else remains theirs.
                if let postTitle, existing.title == fallbackTitle || existing.title == ObsidianMarkdownParser.fileNameTitle(fallbackTitle) {
                    existing.title = postTitle
                }
                existing.deletedAt = nil
                return .records(existing, try repository.loadListeningMap(itemId: itemId), document)
            }
        }
        let mapPolicy: DeterministicListeningMapPolicy = isPDF ? .canonicalHeadings : .authoredSections
        let deterministicMap = document.map { StructuredDocumentImport.listeningMap(for: $0, title: title, itemId: itemId) }
            ?? parsedMarkdown?.deterministicListeningMap(
                itemId: itemId,
                policy: mapPolicy
            )
        let source = parsedMarkdown?.source ?? handoff.source.url
        let item = Item(
            id: itemId,
            title: displayTitle,
            mediaType: isPDF || sourceExtension == "pdf" ? "pdf" : "text",
            text: text,
            externalReference: source,
            status: deterministicMap == nil ? "needs_listening_map" : "ready",
            externalReferenceType: handoff.captureMode == .markdownFile || handoff.captureMode == .plainTextFile ? "file" : "url",
            createdAt: Date(),
            documentStructure: handoff.documentStructure
        )
        return .records(item, deterministicMap, document)
    }

    /// The id of the PDF already imported from this https address. A listener's own copy comes before one in Recently
    /// Deleted, and the oldest before a newer one. A later edition has `-edition-` and a SHA-256 at the end of its id;
    /// editions are made from the original, never from each other, so only an original is a match.
    private func existingPDFItemId(atHTTPSAddress address: String) throws -> String? {
        guard URLComponents(string: address)?.scheme?.lowercased() == "https" else { return nil }
        let sameAddress: [Item]
        if let lookup = repository as? any ItemAddressLookup {
            sameAddress = try lookup.listItems(withExternalReference: address)
        } else {
            sameAddress = try repository.listItems(includeDeleted: true).filter { $0.externalReference == address }
        }
        return sameAddress
            .filter { $0.mediaType == "pdf" && $0.id.hasPrefix("item-browser-") && $0.id.range(of: #"-edition-[0-9a-f]{64}$"#, options: .regularExpression) == nil }
            .min { lhs, rhs in
                if (lhs.deletedAt == nil) != (rhs.deletedAt == nil) { return lhs.deletedAt == nil }
                let (l, r) = (lhs.createdAt ?? .distantFuture, rhs.createdAt ?? .distantFuture)
                return l != r ? l < r : lhs.id < rhs.id
            }?.id
    }

    private func existingItem(id: String) throws -> Item? {
        do { return try repository.loadItem(id: id) }
        catch SessionKitError.missingFixture(let key) where key == "item:\(id)" || key == id { return nil }
    }

    private func cleanedBrowserTextTitle(_ title: String, url: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else {
            return "Browser Text"
        }
        return host
    }

    private func browserTextItemId(title: String, url: String) -> String {
        let base = [title, url].joined(separator: "-").lowercased()
        let allowed = CharacterSet.alphanumerics
        let slug = base.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "item-browser-\(collapsed.prefix(48))"
    }

    /// The three writes of an import, in the order the engine always made them. `item` is already in the form the
    /// Library stores (never the publisher's recording as its audio).
    func persist(_ item: Item, map: ListeningMap?, document: StructuredDocument?) throws {
        try repository.saveItem(item)
        if let map { try repository.saveListeningMap(map) }
        guard let document, let store = repository as? any StructuredDocumentRepository else { return }
        if let store = store as? any (SessionRepository & StructuredDocumentRepository) {
            try PreparedAudioEnqueue.saveStructuredDocument(document, itemId: item.id, repository: store)
        } else { try store.saveStructuredDocument(document, itemId: item.id) }
    }
}
