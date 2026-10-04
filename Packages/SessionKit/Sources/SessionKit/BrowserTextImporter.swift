#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Persistence-only browser/PDF importer. No reference to the live playback engine
/// crosses the suspension point; the repository owns synchronization.
public struct BrowserTextImporter: Sendable {
    private let repository: any SessionRepository
    private let excludingItemId: String?
    private let heldItems: HeldItems?

    public init(repository: any SessionRepository, excludingItemId: String? = nil) {
        self.repository = repository
        self.excludingItemId = excludingItemId
        self.heldItems = nil
    }

    /// The engine's held items are read when the upgrade commits, not when the import starts.
    init(repository: any SessionRepository, heldItems: HeldItems) {
        self.repository = repository
        self.excludingItemId = nil
        self.heldItems = heldItems
    }

    public func importInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) async throws -> Item {
        try await importReportingUpgrade(handoff, structuredDocument: structuredDocument).0
    }

    /// The imported item, and whether it was an existing item moved to the new extraction.
    func importReportingUpgrade(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) async throws -> (Item, Bool) {
        try await Task.detached(priority: .userInitiated) {
            let (item, _, _, upgraded) = try self.importRecords(handoff, structuredDocument: structuredDocument)
            return (item, upgraded)
        }.value
    }

    func importRecords(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws -> (Item, ListeningMap?, StructuredDocument?, upgraded: Bool) {
        let (item, map, document, persisted) = try records(handoff, structuredDocument: structuredDocument)
        // A completed upgrade has already saved everything atomically. Saving it a
        // second time could overwrite changes that arrived just after its commit.
        if !persisted {
            let save = {
                try repository.saveItem(item)
                if let map { try repository.saveListeningMap(map) }
                if let document, let store = repository as? any StructuredDocumentRepository {
                    // An item with a document is spoken through it, so preparation of its
                    // plain text can't commit any more; retire it as an upgrade does, or its
                    // job is picked again forever. This is the identical-text re-import, whose
                    // positions don't move (#344 audit 4).
                    if try store.loadStructuredDocument(itemId: item.id) == nil {
                        for manifest in try repository.loadPreparedAudioManifests(itemId: item.id) {
                            try repository.deletePreparedAudioManifest(id: manifest.id)
                        }
                        for job in try repository.loadAudioPreparationJobs() where job.itemId == item.id {
                            try repository.deleteAudioPreparationJob(id: job.id)
                        }
                    }
                    try store.saveStructuredDocument(document, itemId: item.id)
                }
            }
            if let store = repository as? any SessionRepositoryTransaction {
                try store.withSessionTransaction(save)
            } else {
                try save()
            }
        }
        return (item, map, document, persisted)
    }

    /// Commits the upgrade unless the engine picked the item up while it was being
    /// planned; the engine then holds the old text, so the new one becomes an edition.
    private func commitUnlessHeld(
        _ upgrade: StructuredDocumentUpgrade,
        store: any (SessionRepository & StructuredDocumentRepository)
    ) throws -> Bool {
        let commit = { () throws -> Bool in
            if heldItems?.contains(upgrade.item.id) == true { return false }
            try store.applyStructuredDocumentUpgrade(upgrade)
            return true
        }
        if let transactional = store as? any SessionRepositoryTransaction {
            return try transactional.withSessionTransaction(commit)
        }
        return try commit()
    }

    private func records(
        _ handoff: BrowserTextHandoff,
        structuredDocument: StructuredDocument? = nil
    ) throws -> (Item, ListeningMap?, StructuredDocument?, Bool) {
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
            parsedMarkdown = try? ObsidianMarkdownParser.parse(fileName: fallbackTitle, contents: rawText)
        } else {
            parsedMarkdown = nil
        }
        let title = parsedMarkdown?.title ?? fallbackTitle
        let text = document?.text ?? (parsedMarkdown?.text ?? rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("importBrowserText")
        }
        var itemId = handoff.itemId ?? browserTextItemId(title: title, url: handoff.source.url)
        if handoff.itemId == nil, handoff.captureMode == .readablePage || isPDF {
            // A corrected extraction (or a new PDF extractor) must not move existing
            // Margin anchors. Retain the original edition and give changed text its
            // own identity.
            if let existing = try existingItem(id: itemId), existing.text != text {
                // C1 M3 step 5: a PDF re-imported with a newer extraction moves the
                // existing item to it when every Margin and position lands on the same
                // words (I13 rule 1d). Otherwise it stays, and the new text becomes
                // its own edition as before.
                if let document, existing.deletedAt == nil, excludingItemId != existing.id,
                   let store = repository as? any (SessionRepository & StructuredDocumentRepository),
                   // A planning error falls back to the plain import below (#322).
                   case .success(let upgrade)? = try? StructuredDocumentUpgrader.plan(
                       existing: existing,
                       document: document,
                       listeningMap: StructuredDocumentImport.listeningMap(for: document, title: existing.title, itemId: existing.id),
                       repository: store
                   ) {
                    do {
                        if try commitUnlessHeld(upgrade, store: store) {
                            return (upgrade.item, upgrade.listeningMap, document, true)
                        }
                    } catch StructuredDocumentUpgrader.StalePlan.changedInputs {
                        // Preserve newer listener changes and import a separate edition.
                    }
                }
                let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                itemId += "-edition-\(digest)"
            }
            if var existing = try existingItem(id: itemId) {
                existing.deletedAt = nil
                return (existing, try repository.loadListeningMap(itemId: itemId), document, false)
            }
        }
        let mapPolicy: DeterministicListeningMapPolicy = isPDF
            ? .canonicalHeadings
            : .adaptiveListeningSections
        let deterministicMap = document.map { StructuredDocumentImport.listeningMap(for: $0, title: title, itemId: itemId) }
            ?? parsedMarkdown?.deterministicListeningMap(
                itemId: itemId,
                policy: mapPolicy
            )
        let source = parsedMarkdown?.source ?? handoff.source.url
        let item = Item(
            id: itemId,
            title: title,
            mediaType: isPDF || sourceExtension == "pdf" ? "pdf" : "text",
            text: text,
            externalReference: source,
            status: deterministicMap == nil ? "needs_listening_map" : "ready",
            externalReferenceType: handoff.captureMode == .markdownFile || handoff.captureMode == .plainTextFile ? "file" : "url",
            createdAt: Date(),
            documentStructure: handoff.documentStructure
        )
        return (item, deterministicMap, document, false)
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

}
