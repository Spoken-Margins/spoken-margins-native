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

struct SourceLinkCandidateReviewState: Identifiable, Equatable {
    let request: LinkResolutionRequest
    let result: LinkResolutionResult
    let startSession: Bool

    var id: String { request.id }
}

enum BatchSessionExportFilter: String, CaseIterable, Identifiable {
    case withInterjections = "with_interjections"
    case all = "all"

    var id: String { rawValue }
}

struct BatchSessionExportRow: Identifiable {
    let session: Session
    let itemTitle: String
    let interjectionCount: Int

    var id: String { session.id }
}

struct QuickAccessFile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAt: Date
    let modifiedAtDescription: String

    var dismissalKey: String {
        "\(id)|\(Int(modifiedAt.timeIntervalSince1970))"
    }
}

enum QuickAddCandidate: Identifiable, Sendable {
    case localFile(QuickAccessFile)
    case followedSource(FeedEntry)

    var id: String {
        switch self {
        case .localFile(let file): "local-file:\(file.id)"
        case .followedSource(let entry): "followed-source:\(entry.id)"
        }
    }

    fileprivate var sortDate: Date {
        switch self {
        case .localFile(let file): file.modifiedAt
        case .followedSource(let entry): entry.publishedAt ?? .distantPast
        }
    }
}

private struct ObsidianImportRequest: Sendable {
    let url: URL
    let itemId: String
}

private struct PreparedObsidianImport: Sendable {
    let item: Item
    let listeningMap: ListeningMap?
    var structuredDocument: StructuredDocument? = nil
}

private struct ImportedSourceText: Sendable {
    let text: String
    let documentStructure: PDFDocumentStructure?
    /// A PDF's extraction v2 (C1 M3) and the title v1 would have given it.
    var structuredDocument: StructuredDocument? = nil
    var title: String? = nil
}

private struct ObsidianImportBatch: Sendable {
    let prepared: [PreparedObsidianImport]
    let failures: [String]
}

private enum SourceFileImportError: LocalizedError {
    case pdfHasNoExtractableText
    case pdfImportUnavailable
    case remotePDFInvalidResponse
    case remotePDFTooLarge

    var errorDescription: String? {
        switch self {
        case .pdfHasNoExtractableText:
            return "This PDF has no extractable text. Scanned PDFs need OCR before they can be imported."
        case .pdfImportUnavailable:
            return "PDF text extraction is unavailable in this build."
        case .remotePDFInvalidResponse:
            return "The shared link did not return a readable PDF."
        case .remotePDFTooLarge:
            return "This PDF is larger than the 50 MB import limit."
        }
    }
}

struct QuickAccessFileCandidate: Sendable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAt: Date
}

struct QuickAccessFolderScan: Sendable {
    let files: [QuickAccessFileCandidate]
    let errorDescription: String?
}

struct ImportInboxEntry: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case sourceLink
        case browserText
    }

    let id: String
    let payloadID: String
    let kind: Kind
    let title: String
    let source: String
    let reason: String
}

extension Gate1AppModel {
    var displayedExportPreview: String {
        guard exportPreview.count > Self.exportPreviewCharacterLimit else { return exportPreview }
        return String(exportPreview.prefix(Self.exportPreviewCharacterLimit))
            + "\n\n… Preview truncated. Copy or Share uses the complete export."
    }

    var exportPreviewIsTruncated: Bool {
        exportPreview.count > Self.exportPreviewCharacterLimit
    }

    var exportPreviewSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(exportPreview.utf8.count),
            countStyle: .file
        )
    }

    func importTextItem(startListening: Bool = true) {
        do {
            let store = try requireStore()
            let preservesActiveSession = !startListening && hasActiveSession && engine != nil
            let itemId = "item-import-\(UUID().uuidString.lowercased())"
            let enteredTitle = importTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try ObsidianMarkdownParser.parse(
                fileName: enteredTitle.isEmpty ? "\(importText.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")).md" : "\(enteredTitle).md",
                contents: importText,
                titleOverride: enteredTitle.isEmpty ? nil : enteredTitle
            )
            let deterministicMap = parsed.deterministicListeningMap(itemId: itemId, policy: .canonicalHeadings)
            let item = Item(
                id: itemId,
                title: enteredTitle.isEmpty ? parsed.title : enteredTitle,
                mediaType: "text",
                text: parsed.text,
                externalReference: "manual-import",
                status: deterministicMap == nil ? "needs_listening_map" : "ready",
                externalReferenceType: "manual"
            )
            try store.seed(item: item)
            if let deterministicMap {
                try store.saveListeningMap(deterministicMap)
                diagnostics["lastListeningMapMode"] = "deterministic_headings"
                diagnostics["lastGeneratedMapItem"] = item.id
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            libraryItems = try loadLibraryRows(store: store)
            if !preservesActiveSession && startListening {
                activeItemId = item.id
                selectedItem = try loadItemDetail(id: item.id, store: store)
            }
            diagnostics["lastImport"] = item.id
            markOnboardingSteps([.addedOwnSource])
            importTitle = ""
            importText = ""
            if startListening {
                startItem(id: item.id)
            } else {
                reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
            }
        } catch {
            reportFailure(error, context: "Import failed")
        }
    }

    func pasteImportTextFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain text.")
            return
        }
        let html = UIPasteboard.general.data(forPasteboardType: "public.html")
            .flatMap { $0.count <= 2_000_000 ? String(data: $0, encoding: .utf8) : nil }
        importText = Self.pastedSourceText(plainText: clipboardText, html: html)
        reportSuccess("Pasted text from Clipboard.")
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    func importObsidianMarkdownFiles(urls: [URL]) {
        beginObsidianMarkdownImport(urls: urls, securityScopedURLs: urls)
    }

    func importEPUBFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importEPUB(from: url)
                guard let store = self.store else { return }
                self.libraryItems = try self.loadLibraryRows(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
                if openWhenFinished {
                    self.selectedItem = try self.loadItemDetail(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
                }
            } catch {
                self.reportFailure(error, context: "EPUB import failed")
            }
        }
    }

    func importAudiobookFile(url: URL, openWhenFinished: Bool = true) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let importer = try self.requireLocalSourceImporter()
                let item = try await importer.importAudiobook(from: url)
                guard let store = self.store else { return }
                self.libraryItems = try self.loadLibraryRows(store: store)
                self.markOnboardingSteps([.addedOwnSource, .addedFromFiles])
                self.refreshSpokenMarginsPackageImportAfterAddingSource()
                if openWhenFinished {
                    self.selectedItem = try self.loadItemDetail(id: item.id, store: store)
                    self.activeItemId = item.id
                    self.screen = .item
                    self.reportConfirmation("Imported \(item.title).")
                } else {
                    self.reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
                }
            } catch {
                self.reportFailure(error, context: "Audiobook import failed")
            }
        }
    }

    var isImportingSources: Bool {
        sourceImportProgressMessage != nil
    }

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

    var hasQuickAccessFolder: Bool {
        UserDefaults.standard.data(forKey: quickAccessFolderBookmarkKey) != nil
    }

    var isRefreshingQuickAddFeed: Bool {
        isRefreshingQuickAccessFolder || isRefreshingFollowedSources
    }

    nonisolated static func quickAddCandidates(
        folderFiles: [QuickAccessFile],
        followedEntries: [FeedEntry],
        subscriptions: [FeedSubscription] = [],
        libraryItems: [LibraryItemRow] = [],
        dismissedFileKeys: Set<String> = []
    ) -> [QuickAddCandidate] {
        let importedURLs = Set(libraryItems.compactMap { normalizedQuickAddURL($0.sourceReference) })
        let importedEpisodeKeys = Set(libraryItems.map {
            quickAddEpisodeKey(title: $0.title, sourceTitle: $0.sourceTitle)
        })
        let sourceTitles = Dictionary(uniqueKeysWithValues: subscriptions.map {
            ($0.id, $0.source.title ?? $0.source.host)
        })
        let eligibleFiles = folderFiles.filter { !dismissedFileKeys.contains($0.dismissalKey) }
        let eligibleEntries = followedEntries.filter { entry in
            if let normalizedURL = normalizedQuickAddURL(entry.canonicalURL), importedURLs.contains(normalizedURL) {
                return false
            }
            let episodeKey = quickAddEpisodeKey(
                title: entry.title,
                sourceTitle: sourceTitles[entry.subscriptionId]
            )
            return !importedEpisodeKeys.contains(episodeKey)
        }
        return (eligibleFiles.map(QuickAddCandidate.localFile)
            + eligibleEntries.map(QuickAddCandidate.followedSource))
            .sorted {
                if $0.sortDate != $1.sortDate {
                    return $0.sortDate > $1.sortDate
                }
                return $0.id < $1.id
            }
    }

    private nonisolated static func normalizedQuickAddURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string
    }

    private nonisolated static func quickAddEpisodeKey(title: String, sourceTitle: String?) -> String {
        [sourceTitle ?? "", title]
            .map {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "|")
    }

    func dismissQuickAccessFile(_ file: QuickAccessFile) {
        dismissedQuickAccessFileKeys.insert(file.dismissalKey)
        UserDefaults.standard.set(
            dismissedQuickAccessFileKeys.sorted(),
            forKey: Self.dismissedQuickAccessFilesKey
        )
    }

    private func beginObsidianMarkdownImport(
        urls: [URL],
        securityScopedURLs: [URL],
        refreshQuickFolderWhenFinished: Bool = false,
        openImportedItemWhenFinished: Bool = false,
        quickAccessFileToDismiss: QuickAccessFile? = nil
    ) {
        guard !urls.isEmpty else {
            reportFailure("Choose at least one Markdown, text, or PDF file to import.")
            return
        }
        guard sourceImportTask == nil else {
            reportFailure("Another source is already importing. You can keep using playback while it finishes.")
            return
        }

        let requests = urls.enumerated().map { index, url in
            ObsidianImportRequest(
                url: url,
                itemId: obsidianItemId(fileName: url.lastPathComponent, index: index)
            )
        }
        let scopedAccess = securityScopedURLs.map { url in
            (url: url, didAccess: url.startAccessingSecurityScopedResource())
        }
        sourceImportProgressMessage = urls.count == 1 ? "Importing \(urls[0].lastPathComponent)…" : "Importing \(urls.count) files…"
        statusMessage = sourceImportProgressMessage ?? "Importing sources…"
        lastError = nil

        sourceImportTask = Task { [weak self] in
            let batch = await Task.detached(priority: .userInitiated) {
                await Self.prepareObsidianImports(requests)
            }.value
            scopedAccess.forEach { entry in
                if entry.didAccess {
                    entry.url.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            self.completeObsidianMarkdownImport(
                batch,
                refreshQuickFolderWhenFinished: refreshQuickFolderWhenFinished,
                openImportedItemWhenFinished: openImportedItemWhenFinished,
                quickAccessFileToDismiss: quickAccessFileToDismiss
            )
        }
    }

    private nonisolated static func prepareObsidianImports(_ requests: [ObsidianImportRequest]) async -> ObsidianImportBatch {
        var prepared: [PreparedObsidianImport] = []
        var failures: [String] = []
        for request in requests {
            do {
                let imported = try await importableText(from: request.url)
                if let document = imported.structuredDocument {
                    let title = imported.title ?? request.url.deletingPathExtension().lastPathComponent
                    let map = StructuredDocumentImport.listeningMap(for: document, title: title, itemId: request.itemId)
                    let item = Item(
                        id: request.itemId,
                        title: title,
                        mediaType: "pdf",
                        text: document.text,
                        externalReference: request.url.lastPathComponent,
                        status: map == nil ? "needs_listening_map" : "ready",
                        externalReferenceType: "file",
                        createdAt: Date(),
                        documentStructure: imported.documentStructure
                    )
                    prepared.append(PreparedObsidianImport(item: item, listeningMap: map, structuredDocument: document))
                    continue
                }
                let parsed = try ObsidianMarkdownParser.parse(fileName: request.url.lastPathComponent, contents: imported.text)
                let mapPolicy: DeterministicListeningMapPolicy = request.url.pathExtension.lowercased() == "pdf"
                    ? .canonicalHeadings
                    : .adaptiveListeningSections
                let deterministicMap = parsed.deterministicListeningMap(
                    itemId: request.itemId,
                    policy: mapPolicy
                )
                let item = Item(
                    id: request.itemId,
                    title: parsed.title,
                    mediaType: request.url.pathExtension.lowercased() == "pdf" ? "pdf" : "text",
                    text: parsed.text,
                    externalReference: parsed.source ?? request.url.lastPathComponent,
                    status: deterministicMap == nil ? "needs_listening_map" : "ready",
                    externalReferenceType: "file",
                    createdAt: Date(),
                    documentStructure: imported.documentStructure
                )
                prepared.append(PreparedObsidianImport(item: item, listeningMap: deterministicMap))
            } catch {
                failures.append("\(request.url.lastPathComponent): \(error)")
            }
        }
        return ObsidianImportBatch(prepared: prepared, failures: failures)
    }

    private nonisolated static func importableText(from url: URL) async throws -> ImportedSourceText {
        guard url.pathExtension.lowercased() == "pdf" else {
            return ImportedSourceText(
                text: try String(contentsOf: url, encoding: .utf8),
                documentStructure: nil
            )
        }
        #if canImport(PDFKit)
        do {
            let extracted = try NativePDFDocumentExtractor.extractStructured(from: url)
            return ImportedSourceText(
                text: extracted.document.text,
                documentStructure: extracted.documentStructure,
                structuredDocument: extracted.document,
                title: extracted.title
            )
        } catch PDFStructuredTextExtractor.ExtractionError.noExtractableText {
            throw SourceFileImportError.pdfHasNoExtractableText
        }
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    private func completeObsidianMarkdownImport(
        _ batch: ObsidianImportBatch,
        refreshQuickFolderWhenFinished: Bool,
        openImportedItemWhenFinished: Bool,
        quickAccessFileToDismiss: QuickAccessFile?
    ) {
        defer {
            sourceImportTask = nil
            sourceImportProgressMessage = nil
            if refreshQuickFolderWhenFinished {
                refreshQuickAccessFolder()
            }
        }
        do {
            let store = try requireStore()
            let preservesActiveSession = hasActiveSession && engine != nil
            let preservedActiveItemId = activeItemId
            let preservedSelectedItemId = selectedItem.id
            var imported: [Item] = []
            var failures = batch.failures
            for prepared in batch.prepared {
                do {
                    try store.saveItem(prepared.item)
                    if let listeningMap = prepared.listeningMap {
                        try store.saveListeningMap(listeningMap)
                    }
                    if let document = prepared.structuredDocument {
                        try store.saveStructuredDocument(document, itemId: prepared.item.id)
                    }
                    imported.append(prepared.item)
                } catch {
                    failures.append("\(prepared.item.title): \(error)")
                }
            }
            guard !imported.isEmpty else {
                reportFailure(failures.isEmpty ? "No source files were imported." : failures.joined(separator: "\n"))
                return
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            libraryItems = try loadLibraryRows(store: store)
            if openImportedItemWhenFinished, let item = imported.first {
                activeItemId = item.id
                selectedItem = try loadItemDetail(id: item.id, store: store)
                screen = .item
            } else if preservesActiveSession {
                activeItemId = preservedActiveItemId
                if !preservedSelectedItemId.isEmpty {
                    selectedItem = try loadItemDetail(id: preservedSelectedItemId, store: store)
                }
            } else {
                activeItemId = imported.first?.id ?? activeItemId
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
                screen = .home
            }
            if let quickAccessFileToDismiss {
                dismissQuickAccessFile(quickAccessFileToDismiss)
            }
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            if let structure = imported.compactMap(\.documentStructure).last {
                recordPDFExtractionDiagnostics(structure)
            }
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            markOnboardingSteps([.addedOwnSource, .addedFromFiles])
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportConfirmation("Imported \(imported.count) source file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            reportFailure(error, context: "File import failed")
        }
    }

    @discardableResult
    func importSourceLinkFromForm() -> Bool {
        beginSourceLinkImportFromForm(startSession: !hasActiveSession)
    }

    @discardableResult
    func beginSourceLinkImportFromForm(startSession: Bool = true) -> Bool {
        guard !isResolvingSourceLink else { return false }
        let submittedURL = sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: submittedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsedURL.host != nil else {
            sourceLinkImportState = "failure"
            sourceLinkImportMessage = submittedURL.isEmpty
                ? "Paste or enter a link to an article, podcast, feed or audio file first."
                : "Enter a valid web link (http or https) to an article, podcast, feed or audio file."
            reportFailure(sourceLinkImportMessage ?? "Enter a valid source URL.")
            return false
        }
        isResolvingSourceLink = true
        sourceLinkSafariOffer = nil
        sourceLinkImportState = "resolving"
        sourceLinkImportMessage = "Resolving source link…"
        statusMessage = "Resolving source link..."
        lastError = nil
        diagnostics["lastSourceLinkButtonTap"] = "registered"
        Task { @MainActor in
            await Task.yield()
            let imported = await importSourceLinkAsync(
                urlString: parsedURL.absoluteString,
                sourceSurface: "paste",
                startSession: startSession && !hasActiveSession
            )
            if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == submittedURL {
                sourceLinkURL = ""
            }
            let awaitsCandidateReview = sourceLinkCandidateReview?.request.inputURL == parsedURL.absoluteString
            if awaitsCandidateReview {
                sourceLinkImportState = "review"
                sourceLinkImportMessage = "Choose the matching podcast episode."
            } else {
                sourceLinkImportState = imported ? "success" : "failure"
                sourceLinkImportMessage = imported ? "Source added." : (sourceLinkSafariOffer?.message ?? lastError ?? "This source could not be added.")
            }
        }
        return true
    }

    func pasteSourceLinkFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain a URL.")
            return
        }
        let pasted = Self.firstURL(in: clipboardText)?.absoluteString ?? clipboardText
        sourceLinkURL = pasted
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        reportSuccess("Pasted link from Clipboard.")
        diagnostics["lastSourceLinkClipboardPaste"] = pasted
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    /// Fills the Following feed field from the clipboard (#153). Returns false when the clipboard has no link.
    @discardableResult
    func pasteFollowedSourceFromClipboard() -> Bool {
        #if canImport(UIKit)
        guard let text = UIPasteboard.general.string, let url = Self.firstURL(in: text) else { return false }
        followedSourceURL = url.absoluteString
        return true
        #else
        return false
        #endif
    }

    func resetSourceLinkImportState() {
        guard !isResolvingSourceLink else { return }
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = nil
        sourceLinkSafariOffer = nil
    }

    @discardableResult
    func importSourceLink(_ handoff: SourceLinkHandoff) -> Bool {
        importSourceLink(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(_ handoff: SourceLinkHandoff) async -> Bool {
        await importSourceLinkAsync(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession && !hasActiveSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(urlString: String, sourceSurface: String, startSession: Bool = true) async -> Bool {
        withdrawRetryOffer("sourceLink")
        let shouldStartSession = startSession && !hasActiveSession
        guard sourceLinkResolver == nil else {
            return importSourceLink(urlString: urlString, sourceSurface: sourceSurface, startSession: shouldStartSession)
        }
        isResolvingSourceLink = true
        statusMessage = "Resolving source link..."
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        let request = LinkResolutionRequest(
            id: "source-link-\(Int(Date().timeIntervalSince1970))",
            inputURL: url.absoluteString,
            sourceSurface: sourceSurface,
            createdAt: Date()
        )
        do {
            let result = try await PublicPodcastLinkResolver().resolveAsync(request)
            if let article = await readLinkAsArticleOrOfferSafari(url, after: result, startSession: shouldStartSession) {
                return importBrowserText(article)
            }
            return importResolvedSourceLink(request: request, result: result, startSession: shouldStartSession)
        } catch {
            offerSafariIfUnreadable(url, error: error)
            reportFailure(error, context: "Source link import failed", retry: .init(key: "sourceLink") { [weak self] in
                self?.sourceLinkURL = urlString
                _ = self?.beginSourceLinkImportFromForm(startSession: startSession)
            })
            return false
        }
    }

    @discardableResult
    func importSourceLink(urlString: String, sourceSurface: String, startSession: Bool = true) -> Bool {
        let shouldStartSession = startSession && !hasActiveSession
        if hasActiveSession, sourceLinkResolver == nil {
            Task { @MainActor in
                _ = await importSourceLinkAsync(
                    urlString: urlString,
                    sourceSurface: sourceSurface,
                    startSession: false
                )
            }
            return true
        }
        isResolvingSourceLink = true
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        do {
            if !shouldStartSession, let sourceLinkResolver {
                let request = LinkResolutionRequest(
                    id: "source-link-\(Int(Date().timeIntervalSince1970))",
                    inputURL: url.absoluteString,
                    sourceSurface: sourceSurface,
                    createdAt: Date()
                )
                return importResolvedSourceLink(
                    request: request,
                    result: try sourceLinkResolver.resolve(request),
                    startSession: false
                )
            }
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            statusMessage = "Resolving source link..."
            let request = LinkResolutionRequest(
                id: "source-link-\(Int(Date().timeIntervalSince1970))",
                inputURL: url.absoluteString,
                sourceSurface: sourceSurface,
                createdAt: Date()
            )
            let imported = try engine.importSourceLink(request, startSessionWhenPlayable: shouldStartSession)
            snapshot = shouldStartSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = engine.lastLinkResolutionResult?.originalLink.provider
                ?? engine.lastLinkResolutionResult?.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.needsReview.rawValue,
               let result = engine.lastLinkResolutionResult,
               presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: shouldStartSession) {
                return false
            }
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = shouldStartSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    let resolved = engine.lastLinkResolutionResult
                    scheduleSourceTranscriptImportIfAvailable(
                        resolved?.selectedCandidate?.transcriptLinks ?? resolved?.candidates.flatMap(\.transcriptLinks) ?? [],
                        itemId: itemId
                    )
                }
                reportConfirmation(shouldStartSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    private func importResolvedSourceLink(request: LinkResolutionRequest, result: LinkResolutionResult, startSession: Bool = true) -> Bool {
        do {
            if presentSourceLinkCandidateReviewIfAvailable(request: request, result: result, startSession: startSession) {
                return false
            }
            if !startSession {
                guard let item = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
                    reportFailure(sourceLinkFailureMessage(
                        status: result.status.rawValue,
                        reason: result.failureReason,
                        provider: result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
                    ))
                    return false
                }
                reportConfirmation("Added \(item.title) to Library without changing Now Playing.")
                return true
            }
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            let imported = try engine.importResolvedSourceLink(request, result: result, startSessionWhenPlayable: startSession)
            snapshot = startSession && imported.linkResolutionStatus == LinkResolutionStatus.playable.rawValue
                ? try applyPreferredPlaybackRate(to: imported, engine: engine)
                : imported
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                markOnboardingSteps([.addedOwnSource, .addedPodcast])
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    schedulePodcastDownloadIfNeeded(itemId: itemId)
                    scheduleSourceTranscriptImportIfAvailable(
                        result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                        itemId: itemId
                    )
                }
                reportConfirmation(startSession ? "Imported and started \(title)." : "Imported \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    private func persistResolvedSourceLinkInBackground(
        request: LinkResolutionRequest,
        result: LinkResolutionResult
    ) throws -> Item? {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(request, result: result) else {
            return nil
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        scheduleSourceTranscriptImportIfAvailable(
            result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
            itemId: item.id
        )
        return item
    }

    private func presentSourceLinkCandidateReviewIfAvailable(
        request: LinkResolutionRequest,
        result: LinkResolutionResult,
        startSession: Bool
    ) -> Bool {
        let playableCandidates = result.candidates.filter { candidate in
            guard let audioURL = candidate.audioURL,
                  let url = URL(string: audioURL) else { return false }
            return url.scheme?.lowercased() == "https"
        }
        guard result.status == .needsReview, playableCandidates.count > 1 else { return false }
        var reviewResult = result
        reviewResult.candidates = playableCandidates
        sourceLinkCandidateReview = SourceLinkCandidateReviewState(
            request: request,
            result: reviewResult,
            startSession: startSession
        )
        diagnostics["lastSourceLinkReviewCandidates"] = "\(playableCandidates.count)"
        reportSuccess("Choose the matching podcast episode. Nothing has been imported yet.")
        return true
    }

    func selectSourceLinkCandidate(_ candidate: LinkResolutionCandidate) {
        guard let review = sourceLinkCandidateReview,
              review.result.candidates.contains(candidate) else { return }
        sourceLinkCandidateReview = nil
        var selected = review.result
        selected.status = .playable
        selected.selectedCandidate = candidate
        selected.candidates = [candidate]
        selected.failureReason = nil
        let imported = importResolvedSourceLink(request: review.request, result: selected, startSession: review.startSession)
        sourceLinkImportState = imported ? "success" : "failure"
        sourceLinkImportMessage = imported ? "Source added." : (lastError ?? "This source could not be added.")
        if imported, sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines) == review.request.inputURL {
            sourceLinkURL = ""
        }
    }

    func cancelSourceLinkCandidateReview() {
        sourceLinkCandidateReview = nil
        sourceLinkImportState = "idle"
        sourceLinkImportMessage = "Podcast import cancelled."
        reportSuccess("Podcast import cancelled. Nothing was added.")
    }

    @discardableResult
    func importSourceLinkInBackground(_ handoff: SourceLinkHandoff, feedEntry: FeedEntry? = nil, subscription: FeedSubscription? = nil) async throws -> String? {
        let trimmed = handoff.inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if handoff.sourceSurface == "share_sheet_pdf_file",
           let fileURL = URL(string: trimmed),
           fileURL.isFileURL {
            let handoffStore = try SourceLinkHandoffStore.appGroup()
            guard handoffStore.isManagedPDFURL(fileURL) else {
                throw SessionKitError.persistenceFailed("The shared PDF is no longer available to import.")
            }
            try await importLocalSharedPDFInBackground(url: fileURL)
            handoffStore.deleteManagedPDF(at: fileURL)
            return nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SessionKitError.persistenceFailed("This share does not contain a valid podcast, RSS, or audio URL.")
        }
        if Self.isRemotePDFHandoff(handoff) {
            try await importRemotePDFInBackground(url: url)
            return nil
        }
        let request = LinkResolutionRequest(
            id: handoff.id,
            inputURL: url.absoluteString,
            sourceSurface: handoff.sourceSurface,
            createdAt: Date()
        )
        let result: LinkResolutionResult
        if let sourceLinkResolver {
            result = try sourceLinkResolver.resolve(request)
        } else {
            result = try await PublicPodcastLinkResolver().resolveAsync(request)
        }
        guard result.status == .playable else {
            if feedEntry == nil, let article = try await LinkArticleFallback.article(for: url, after: result, startSession: false, using: readablePageExtractor, record: { diagnostics["lastSourceLinkArticleFallback"] = $0 }) {
                try importBrowserTextInBackground(article); return nil
            }
            let provider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkFailureCategory"] = result.failureReason
                ?? result.status.rawValue
            throw SessionKitError.persistenceFailed(sourceLinkFailureMessage(
                status: result.status.rawValue,
                reason: result.failureReason,
                provider: provider
            ))
        }

        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine,
              let item = try engine.importResolvedSourceLinkInBackground(
                request,
                result: result,
                sourceIdentity: feedEntry.map { "\($0.subscriptionId):\($0.id)" }
              ) else {
            throw SessionKitError.persistenceFailed("The shared podcast did not expose playable audio.")
        }
        if let feedEntry {
            var identified = item
            let title = feedEntry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { identified.title = title }
            identified.sourceTitle = subscription?.source.title ?? identified.sourceTitle
            identified.sourceURL = subscription?.source.canonicalURL ?? identified.sourceURL
            identified.externalReference = feedEntry.canonicalURL
            identified.author = feedEntry.author ?? identified.author
            feedEntry.fillEpisodeIdentity(of: &identified, showTitle: subscription?.source.title)
            try store.saveItem(identified)
            if item.media?.url == result.selectedCandidate?.audioURL,
               try store.loadListeningMap(itemId: item.id) == nil,
               let summary = feedEntry.summary,
               let chapters = TimestampedDescriptionChapterParser.parse(summary) {
                _ = try engine.attachPublisherChapters(itemId: item.id, collection: chapters)
            }
            diagnostics["sourceEntryImport:\(feedEntry.id)"] = "item:\(item.id),subscription:\(feedEntry.subscriptionId),title:feed_entry"
        }
        libraryItems = try loadLibraryRows(store: store)
        diagnostics["lastBackgroundSourceLinkImport"] = item.id
        markOnboardingSteps([.addedOwnSource, .addedPodcast])
        schedulePodcastDownloadIfNeeded(itemId: item.id)
        if item.media?.url == result.selectedCandidate?.audioURL, item.transcriptId == nil {
            scheduleSourceTranscriptImportIfAvailable(
                result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                itemId: item.id
            )
        }
        return item.id
    }

    static func isRemotePDFHandoff(_ handoff: SourceLinkHandoff) -> Bool { handoff.isRemotePDF }

    private func importLocalSharedPDFInBackground(url: URL) async throws {
        #if canImport(PDFKit)
        let extracted = try await Task.detached(priority: .userInitiated) {
            try NativePDFDocumentExtractor.extractStructured(from: url)
        }.value
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = extracted.title ?? (fileTitle.isEmpty ? "Shared PDF" : fileTitle)
        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "shared.pdf"
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(
                url: "shared-file://share-sheet/\(encodedName)",
                title: title
            ),
            text: extracted.document.text,
            contentFormat: .plainText,
            documentStructure: extracted.documentStructure
        )
        try importBrowserTextInBackground(handoff, structuredDocument: extracted.document)
        diagnostics["lastSharedPDFImport"] = url.lastPathComponent
        markOnboardingSteps([.addedOwnSource, .addedFromSafari])
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    private func importRemotePDFInBackground(url: URL) async throws {
        #if canImport(PDFKit)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let pdfHeader = Data("%PDF-".utf8)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              data.prefix(1_024).range(of: pdfHeader) != nil else {
            throw SourceFileImportError.remotePDFInvalidResponse
        }
        guard data.count <= 50 * 1_024 * 1_024 else {
            throw SourceFileImportError.remotePDFTooLarge
        }
        let extracted = try await Task.detached(priority: .userInitiated) {
            try NativePDFDocumentExtractor.extractStructured(from: data)
        }.value
        let decodedName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding
            ?? url.deletingPathExtension().lastPathComponent
        let fileTitle = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handoff = BrowserTextHandoff(
            captureMode: .markdownFile,
            source: BrowserTextSource(
                url: url.absoluteString,
                title: extracted.title ?? (fileTitle.isEmpty ? "Shared PDF" : fileTitle)
            ),
            text: extracted.document.text,
            contentFormat: .plainText,
            documentStructure: extracted.documentStructure
        )
        try importBrowserTextInBackground(handoff, structuredDocument: extracted.document)
        diagnostics["lastRemotePDFImport"] = url.absoluteString
        markOnboardingSteps([.addedOwnSource, .addedFromSafari])
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    func importBrowserTextInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws {
        let store = try requireStore()
        if engine == nil {
            installEngine(try makeEngine(store: store))
        }
        guard let engine else {
            throw SessionKitError.persistenceFailed("Browser text importer is unavailable.")
        }
        let item = try engine.importBrowserTextInBackground(Self.sanitizedBrowserTextHandoff(handoff), structuredDocument: structuredDocument)
        libraryItems = try loadLibraryRows(store: store)
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
        diagnostics["lastBackgroundBrowserTextImport"] = item.id
        if let structure = item.documentStructure {
            recordPDFExtractionDiagnostics(structure)
        }
        markOnboardingSteps(onboardingSteps(for: handoff))
    }

    func recordPDFExtractionDiagnostics(_ structure: PDFDocumentStructure) {
        diagnostics["lastPDFExtractionEngine"] = structure.extractionEngine.rawValue
        diagnostics["lastPDFAnalysisStatus"] = structure.analysisStatus.rawValue
        diagnostics["lastPDFPageCount"] = "\(structure.pageCount)"
        diagnostics["lastPDFAnalyzedPageCount"] = "\(structure.analyzedPageCount)"
        diagnostics["lastPDFTableCount"] = "\(structure.tables.count)"
    }

    private func onboardingSteps(for handoff: BrowserTextHandoff) -> Set<OnboardingStep> {
        switch handoff.captureMode {
        case .markdownFile, .plainTextFile:
            return [.addedOwnSource, .addedFromFiles]
        case .selectedText, .readablePage:
            return [.addedOwnSource, .addedFromSafari]
        }
    }

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

    nonisolated static func scanQuickAccessFolder(_ folderURL: URL) -> QuickAccessFolderScan {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let supported = files.compactMap { url -> QuickAccessFileCandidate? in
                let ext = url.pathExtension.lowercased()
                guard ["md", "markdown", "txt", "pdf"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return QuickAccessFileCandidate(
                    id: url.lastPathComponent,
                    name: url.deletingPathExtension().lastPathComponent,
                    relativePath: url.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            return QuickAccessFolderScan(
                files: Array(supported.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8)),
                errorDescription: nil
            )
        } catch {
            return QuickAccessFolderScan(files: [], errorDescription: String(describing: error))
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

    @discardableResult
    func importBrowserText(_ handoff: BrowserTextHandoff) -> Bool {
        do {
            if hasActiveSession {
                try importBrowserTextInBackground(handoff)
                reportConfirmation("Added \(handoff.source.title) to Library without changing Now Playing.")
                return true
            }
            let store = try requireStore()
            let engine = try makeEngine(store: store)
            installEngine(engine)
            let shouldStart = handoff.requestedContinuation.startSession
            var importOnlyHandoff = Self.sanitizedBrowserTextHandoff(handoff)
            importOnlyHandoff.requestedContinuation.startSession = false
            snapshot = try engine.importBrowserText(importOnlyHandoff)
            guard let importedItemId = snapshot.itemId ?? handoff.itemId else {
                throw SessionKitError.persistenceFailed("browser_text_item_id")
            }
            activeItemId = importedItemId
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: importedItemId, store: store)
            scheduleTextAudioPrewarmIfNeeded(itemId: importedItemId)
            diagnostics["lastBrowserTextImport"] = importedItemId
            diagnostics["lastBrowserTextSource"] = handoff.source.url
            markOnboardingSteps(onboardingSteps(for: handoff))
            if shouldStart {
                startItem(id: importedItemId)
            } else {
                screen = .item
                reportConfirmation("Imported browser text from \(handoff.source.title).")
            }
            return true
        } catch {
            reportFailure(error, context: "Browser text import failed")
            return false
        }
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
    }

    func openExport() {
        openExport(sessionId: nil)
    }

    func openExport(sessionId: String?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        exportSessionId = sessionId
            ?? (snapshot.itemId == selectedItem.id ? snapshot.sessionId : nil)
            ?? selectedItem.sessions.first?.id
        screen = .export
        refreshExportPreview(reportStatus: false)
    }

    func openBatchExport() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_batch_export") else { return }
        syncPlaybackProgressForLifecycle()
        exportSessionId = nil
        exportPreview = ""
        batchExportFilter = .withInterjections
        selectedBatchExportSessionIds = []
        batchExportResult = nil
        do {
            let store = try requireStore()
            try refreshBatchExportRows(store: store)
            screen = .batchExport
        } catch {
            reportFailure(error, context: "Session export setup failed")
        }
    }

    var visibleBatchExportRows: [BatchSessionExportRow] {
        switch batchExportFilter {
        case .withInterjections:
            batchExportRows.filter { $0.interjectionCount > 0 }
        case .all:
            batchExportRows
        }
    }

    var hasBatchExportFolder: Bool {
        UserDefaults.standard.data(forKey: batchExportFolderBookmarkKey) != nil
    }

    func toggleBatchExportSelection(sessionId: String) {
        if selectedBatchExportSessionIds.contains(sessionId) {
            selectedBatchExportSessionIds.remove(sessionId)
        } else {
            selectedBatchExportSessionIds.insert(sessionId)
        }
        batchExportResult = nil
    }

    func selectAllVisibleBatchExportSessions() {
        selectedBatchExportSessionIds.formUnion(visibleBatchExportRows.map(\.id))
        batchExportResult = nil
    }

    func clearBatchExportSelection() {
        selectedBatchExportSessionIds = []
        batchExportResult = nil
    }

    func buildExport() {
        refreshExportPreview(reportStatus: true)
    }

    func exportOptionsChanged() {
        persistExportSettings()
        refreshExportPreview(reportStatus: false)
    }

    private func refreshExportPreview(reportStatus: Bool) {
        exportShareCandidates = []
        guard let exportSessionId else {
            exportPreview = ""
            exportFileURL = nil
            return
        }
        run { engine in
            let store = try requireStore()
            exportShareCandidates = try store.loadInterjections(sessionId: exportSessionId)
                .filter { $0.status == "active" && $0.targetType == .item }
            let export = try engine.buildExport(options: currentExportOptions())
            exportPreview = try renderExport(export)
            exportFileURL = exportFormat == "markdown"
                ? try prepareIndividualMarkdownExportFile(markdown: exportPreview, export: export)
                : nil
            screen = .export
            if reportStatus {
                reportSuccess("Built session export.")
            }
        }
    }

    func copyPlainTextExport() {
        guard !exportPreview.isEmpty else {
            reportFailure("No export text is available yet.")
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = exportPreview
        recordSessionExported()
        reportConfirmation("Copied \(exportFormat == "json" ? "JSON" : "Markdown") export.")
        #else
        reportFailure("Clipboard is unavailable on this platform.")
        #endif
    }

    func configureBatchExportFolder(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(
                options: quickAccessBookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: batchExportFolderBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "batchExportFolderName")
            UserDefaults.standard.set(UUID().uuidString, forKey: "marginOutputDestinationID")
            batchExportFolderName = url.lastPathComponent
            batchExportResult = nil
            reportSuccess("Export folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Export folder setup failed")
        }
    }

    func reportBatchExportFolderFailure(_ error: Error) {
        reportFailure(error, context: "Export folder selection failed")
    }

    func exportSelectedSessionsToFolder() {
        guard !selectedBatchExportSessionIds.isEmpty else {
            reportFailure("Choose at least one session to export.")
            return
        }
        guard let folderURL = resolvedBatchExportFolderURL() else {
            reportFailure("Choose an export folder first.")
            return
        }
        do {
            if engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let engine else {
                reportFailure("Session export is unavailable.")
                return
            }

            persistExportSettings()
            isWritingBatchExport = true
            defer { isWritingBatchExport = false }

            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            let writer = SessionMarkdownFileWriter()
            let selectedRows = batchExportRows.filter { selectedBatchExportSessionIds.contains($0.id) }
            var exportedFileNames: [String] = []
            var failures: [String] = []
            for row in selectedRows {
                do {
                    let export = try engine.buildExport(options: currentExportOptions(sessionId: row.id))
                    let markdown = SessionExportMarkdownRenderer.render(export)
                    let fileURL = try writer.write(
                        markdown: markdown,
                        itemTitle: row.itemTitle,
                        sessionDate: row.session.createdAt ?? row.session.updatedAt,
                        sessionId: row.id,
                        to: folderURL
                    )
                    exportedFileNames.append(fileURL.lastPathComponent)
                } catch {
                    failures.append("\(row.itemTitle): \(error.localizedDescription)")
                }
            }

            batchExportResult = BatchSessionExportResult(
                exportedFileNames: exportedFileNames,
                failures: failures,
                destinationName: folderURL.lastPathComponent
            )
            if !exportedFileNames.isEmpty {
                markOnboardingSteps([.exportedSession])
            }
            diagnostics["batchExportLastResult"] = "exported=\(exportedFileNames.count);failed=\(failures.count)"
            if failures.isEmpty {
                reportConfirmation("Exported \(exportedFileNames.count) Markdown file\(exportedFileNames.count == 1 ? "" : "s") to \(folderURL.lastPathComponent).")
            } else if exportedFileNames.isEmpty {
                reportFailure("No sessions were exported. Review the export result for details.")
            } else {
                reportFailure("Exported \(exportedFileNames.count) session\(exportedFileNames.count == 1 ? "" : "s"); \(failures.count) failed.")
            }
        } catch {
            isWritingBatchExport = false
            reportFailure(error, context: "Batch export failed")
        }
    }

    func copyTargetInterjections(targetType: String, targetId: String, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: snapshot.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                // Timeline-level note copying is intentionally compact. Full AI
                // responses belong to the configurable Export screen; this path
                // carries only the selected notes and their bounded anchors.
                includeTurns: false,
                scope: "target",
                targetType: targetType,
                targetId: targetId
            ))
            guard !export.interjections.isEmpty else {
                reportFailure("No Margins are available for that target.")
                return
            }
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied target Margins.")
            #else
            exportPreview = text
            reportSuccess("Built target Margin export.")
            #endif
        }
    }

    func copyInterjectionWithContext(_ interjection: Interjection, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: interjection.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                includeTurns: false,
                scope: "selected_interjections",
                interjectionIds: [interjection.id]
            ))
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied Margin with its anchors.")
            #else
            exportPreview = text
            reportSuccess("Built Margin export.")
            #endif
        }
    }

    func refreshImportInbox() {
        var entries: [ImportInboxEntry] = []
        do {
            for failed in try resolvedSourceLinkHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "source:\(failed.id)",
                    payloadID: failed.id,
                    kind: .sourceLink,
                    title: "Podcast or audio link",
                    source: failed.handoff.inputURL,
                    reason: failed.reason
                ))
            }
        } catch {
            diagnostics["sourceLinkImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        do {
            for failed in try resolvedBrowserTextHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "text:\(failed.id)",
                    payloadID: failed.id,
                    kind: .browserText,
                    title: failed.handoff.source.title,
                    source: failed.handoff.source.url,
                    reason: failed.reason
                ))
            }
        } catch {
            diagnostics["browserTextImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        importInbox = entries
    }

    func retryImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().retryFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().retryFailed(payloadID: entry.payloadID)
            }
            importPendingSourceLinkHandoffs()
            reportConfirmation("Import retry queued.")
        } catch {
            reportFailure(error, context: "Import retry failed")
        }
    }

    func deleteImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().deleteFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().deleteFailed(payloadID: entry.payloadID)
            }
            refreshImportInbox()
            reportSuccess("Removed failed import.")
        } catch {
            reportFailure(error, context: "Import removal failed")
        }
    }

    func importPendingSourceLinkHandoffs() {
        Task { @MainActor in
            await importPendingHandoffsAsync()
        }
    }

    private func importPendingHandoffsAsync() async {
        guard !isImportingPendingSourceLinkHandoffs else { return }
        isImportingPendingSourceLinkHandoffs = true
        defer {
            isImportingPendingSourceLinkHandoffs = false
            refreshImportInbox()
        }

        do {
            try consumePendingSpokenMarginsPackageHandoffs(
                from: SpokenMarginsPackageHandoffStore.appGroup()
            )
        } catch {
            diagnostics["pendingSpokenMarginsPackageImport"] = "unavailable:\(error.localizedDescription)"
        }

        do {
            let handoffStore = try resolvedSourceLinkHandoffStore()
            let payloadIDs = try handoffStore.pendingPayloadIDs()
            diagnostics["pendingSourceLinkPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                do {
                    let handoff = try handoffStore.handoff(payloadID: payloadID)
                    try await importSourceLinkInBackground(handoff)
                    try handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "imported"
                } catch SourceLinkHandoffStoreError.invalidPayload {
                    try? handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch SourceLinkHandoffStoreError.missingPayload {
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "missing"
                } catch {
                    try? handoffStore.quarantine(payloadID: payloadID, reason: error.localizedDescription)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "quarantined:\(error.localizedDescription)"
                }
            }
        } catch {
            diagnostics["pendingSourceLinkImport"] = "unavailable:\(error.localizedDescription)"
        }

        do {
            let handoffStore = try resolvedBrowserTextHandoffStore()
            let payloadIDs = try handoffStore.pendingPayloadIDs()
            diagnostics["pendingBrowserTextPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                do {
                    let handoff = try handoffStore.handoff(payloadID: payloadID)
                    try importBrowserTextInBackground(handoff)
                    try handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "imported"
                } catch Gate5BrowserTextHandoffStoreError.invalidPayload {
                    try? handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch Gate5BrowserTextHandoffStoreError.missingPayload {
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "missing"
                } catch {
                    try? handoffStore.quarantine(payloadID: payloadID, reason: error.localizedDescription)
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantined:\(error.localizedDescription)"
                }
            }
        } catch {
            diagnostics["pendingBrowserTextImport"] = "unavailable:\(error.localizedDescription)"
        }
    }

    func consumePendingSpokenMarginsPackageHandoffs(
        from packageStore: SpokenMarginsPackageHandoffStore
    ) throws {
        let payloadIDs = try packageStore.pendingPayloadIDs()
        diagnostics["pendingSpokenMarginsPackages"] = "\(payloadIDs.count)"
        for payloadID in payloadIDs where spokenMarginsPackageImportReview == nil {
            do {
                let packageURL = try packageStore.packageURL(payloadID: payloadID)
                let didOpen = stageSpokenMarginsPackageImport(from: packageURL)
                try packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = didOpen ? "opened" : "rejected"
            } catch {
                try? packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "rejected:\(error.localizedDescription)"
                reportFailure(error, context: "Shared Margins package could not be opened")
            }
        }
    }

    @discardableResult
    private func stageSpokenMarginsPackageImport(from sourceURL: URL) -> Bool {
        var workingDirectory: URL?
        do {
            bootstrapLibraryIfNeeded()
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let root = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/IncomingPackages/\(UUID().uuidString)", directoryHint: .isDirectory)
            workingDirectory = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let copiedPackage = root.appending(path: "package.spokenmargins")
            try FileManager.default.copyItem(at: sourceURL, to: copiedPackage)
            let contents = try SpokenMarginsPackageArchive.read(
                from: copiedPackage,
                extractingAssetsTo: root.appending(path: "assets", directoryHint: .isDirectory)
            )
            guard let digest = contents.manifest.contentDigest else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
            let store = try requireStore()
            if let existing = try store.loadImportedCommentaryLayer(packageDigest: digest),
               importedLayerHasValidItemAssociation(existing, store: store) {
                if let itemId = existing.itemId {
                    openItem(id: itemId)
                    if let item = try? store.loadItem(id: itemId), item.mediaType == "audiobook" {
                        Task { @MainActor [weak self] in
                            defer { try? FileManager.default.removeItem(at: root) }
                            guard let self else { return }
                            do {
                                try await self.verifyLocalAudioForImport(item, contents: contents)
                                try await self.activateImportedLocalAudioMaps(item: item, contents: contents)
                                self.reportSuccess("Restored this listening package. Playback has not started.")
                            } catch { self.reportFailure(error, context: "Restoring listening package failed") }
                        }
                        return true
                    }
                    if let localURL = podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                    reportSuccess("These shared Margins are already in your library. Playback has not started.")
                } else {
                    reportSuccess("These shared Margins are already in your library.")
                }
                diagnostics["lastSpokenMarginsPackageImport"] = "duplicate:\(digest)"
                try? FileManager.default.removeItem(at: root)
                return true
            }
            let matchingItemId = try matchingItemID(for: contents.manifest.item, store: store)
            spokenMarginsPackageImportError = nil
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: copiedPackage,
                extractionDirectory: root,
                contents: contents,
                matchingItemId: matchingItemId
            )
            if try store.loadImportedCommentaryLayer(packageDigest: digest) == nil {
                diagnostics["lastSpokenMarginsPackageImport"] = "previewed:\(digest)"
            } else {
                diagnostics["lastSpokenMarginsPackageImport"] = "repair_previewed:\(digest)"
            }
            return true
        } catch {
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
            diagnostics["lastSpokenMarginsPackageImport"] = "rejected:\(SharedMarginsImportMessage.diagnosticDetail(error))"
            reportFailure(SharedMarginsImportMessage.userFacing(error))
            return false
        }
    }

    func createRecipientTestSessionFromLastSharedPackage() {
        guard let packageURL = sharedSpokenMarginsPackageURL else {
            reportFailure("The last shared package is unavailable.")
            return
        }
        isSharingInterjectionsPresented = false
        isSharedSpokenMarginsPackagePresented = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.stageSpokenMarginsPackageImport(from: packageURL)
        }
    }

    func cancelSpokenMarginsPackageImport() {
        guard !isImportingSpokenMarginsPackage else { return }
        let directory = spokenMarginsPackageImportReview?.extractionDirectory
        spokenMarginsPackageImportReview = nil
        spokenMarginsPackageImportError = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    /// Build 23 presentation code calls this seam instead of asking the user to
    /// reopen the package and repeat integrity verification.
    func refreshSpokenMarginsPackageImportAfterAddingSource() {
        guard let review = spokenMarginsPackageImportReview,
              review.requiresRecipientItem,
              !isImportingSpokenMarginsPackage else { return }
        do {
            let store = try requireStore()
            let matchingItemId = try matchingItemID(for: review.contents.manifest.item, store: store)
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: review.packageURL,
                extractionDirectory: review.extractionDirectory,
                contents: review.contents,
                matchingItemId: matchingItemId
            )
            if matchingItemId == nil {
                spokenMarginsPackageImportError = "That source does not match the item described by this package yet. Add the same item or cancel the import."
            } else {
                spokenMarginsPackageImportError = nil
                reportConfirmation("Source matched. Review the shared Margins before importing.")
            }
        } catch {
            spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
            diagnostics["lastSpokenMarginsPackageImport"] = "source_reconciliation_failed:\(error.localizedDescription)"
        }
    }

    func confirmSpokenMarginsPackageImport() {
        guard let review = spokenMarginsPackageImportReview,
              !isImportingSpokenMarginsPackage else { return }
        guard !review.requiresRecipientItem else {
            spokenMarginsPackageImportError = "This package does not include the item. Add the matching source, then return to this pending import."
            return
        }
        isImportingSpokenMarginsPackage = true
        spokenMarginsPackageImportError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let itemId: String?
                if let matching = review.matchingItemId {
                    itemId = matching
                } else if review.contents.manifest.itemTransport.kind == .embeddedText {
                    itemId = try self.installEmbeddedItem(from: review.contents, store: store)
                } else if review.contents.manifest.item.itemType == .podcast {
                    itemId = try await self.acquirePodcastForImportedPackage(review.contents.manifest.item)
                } else {
                    itemId = nil
                }
                let item = try itemId.map { try store.loadItem(id: $0) }
                let localItem = item.map(self.localSharedItemIdentity(for:))
                if let item, item.mediaType == "audiobook" {
                    try await self.verifyLocalAudioForImport(item, contents: review.contents)
                }
                let itemText = item?.text
                let disposition: ImportedCommentaryImportDisposition
                if let digest = review.contents.manifest.contentDigest,
                   let existing = try store.loadImportedCommentaryLayer(packageDigest: digest) {
                    try self.repairImportedLayerAssociation(
                        existing,
                        contents: review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        store: store
                    )
                    disposition = .duplicate(existingLayerId: existing.id)
                } else {
                    disposition = try SpokenMarginsPackageImporter.importPackage(
                        review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                }
                switch disposition {
                case .duplicate(let existingLayerId):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "duplicate_layer:\(existingLayerId)"
                case .imported(let layerId, let interjectionIds):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "imported:\(layerId):\(interjectionIds.count)"
                }
                if let itemId {
                    self.activeItemId = itemId
                    self.libraryItems = try self.loadLibraryRows(store: store)
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                    self.screen = .item
                    if let item,
                       item.media?.sourceType == .remoteStream,
                       let rawURL = item.media?.url,
                       let remoteURL = URL(string: rawURL) {
                        self.podcastDownloadCoordinator?.register(
                            itemId: itemId,
                            remoteURL: remoteURL,
                            userInitiated: true
                        )
                    }
                    if let item, item.mediaType == "audiobook" {
                        try await self.activateImportedLocalAudioMaps(item: item, contents: review.contents)
                    } else if let localURL = self.podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        self.resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                }
                self.spokenMarginsPackageImportReview = nil
                self.isImportingSpokenMarginsPackage = false
                self.reportConfirmation("Imported shared Margins. Playback has not started.")
            } catch {
                self.isImportingSpokenMarginsPackage = false
                self.spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
                self.diagnostics["lastSpokenMarginsPackageImport"] = "failed:\(error.localizedDescription)"
                self.reportFailure(error, context: "Shared Margins import failed")
            }
        }
    }

    private func verifyLocalAudioForImport(_ item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        guard let url = resolvedOwnedAudiobookURL(for: item) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local source audio is unavailable")
        }
        let actualDigest = try await Task.detached(priority: .utility) {
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        }.value
        let recipient = localSharedItemIdentity(for: item)
        guard actualDigest == recipient.exactEditionSHA256,
              ExactLocalAudioImport.matches(contents.manifest.item, recipient) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("The audio bytes do not match this listening package")
        }
        for proposal in contents.listeningMapProposals {
            _ = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: item.id
            )
        }
    }

    private func activateImportedLocalAudioMaps(item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        let store = try requireStore()
        let recipient = localSharedItemIdentity(for: item)
        for proposal in contents.listeningMapProposals {
            let projection = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: item.id
            )
            for scene in proposal.scenes where scene.summaryAssetId != nil {
                try await adoptSuppliedSummary(scene: scene, proposalId: proposal.id, itemId: item.id, contents: contents, store: store)
            }
            try store.savePortableListeningMapProposal(proposal, itemId: item.id)
            try store.saveResolvedListeningMapProjection(projection)
        }
        if selectedItem.id == item.id { refreshSelectedItem() }
        prepareImportedLocalAudioBridges(itemId: item.id)
    }

    private func adoptSuppliedSummary(
        scene: PortableListeningMapScene, proposalId: String, itemId: String,
        contents: VerifiedSpokenMarginsPackage, store: SQLiteSessionStore
    ) async throws {
        guard let suppliedID = scene.summaryAssetId,
              let descriptor = contents.manifest.assets.first(where: { $0.id == suppliedID && $0.role == SpokenMarginsAssetRole.summaryVoice }),
              let sourceURL = contents.extractedAssetURLs[suppliedID],
              let checksum = descriptor.sha256, let byteCount = descriptor.byteCount else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Supplied summary audio is unavailable")
        }
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: suppliedID)
        let relativePath = "SpokenMargins/EpisodeMaps/\(safePodcastEvidenceComponent(itemId))/SummaryBridges/\(assetID).m4a"
        let support = try applicationSupportDirectory()
        let destination = support.appending(path: relativePath)
        let ledger = offlineStorageLedger ?? OfflineStorageLedger(repository: store, rootDirectory: support)
        let reservation = try await ledger.reserve(ownerId: assetID, byteCount: Int64(byteCount))
        do {
            try await Task.detached(priority: .utility) {
                guard try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL) == checksum else {
                    throw SpokenMarginsPackageArchiveError.invalidAsset(suppliedID)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: sourceURL).write(to: destination, options: .atomic)
            }.value
            try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                id: assetID, itemId: itemId, category: .summaryBridge, relativePath: relativePath,
                byteCount: Int64(byteCount), checksumSHA256: checksum, isReproducible: false
            ))
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    func prepareImportedLocalAudioBridges(itemId: String) {
        guard let store, let item = try? store.loadItem(id: itemId),
              item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream || item.media?.sourceType == .generatedTTSPrerendered,
              let projection = try? store.loadResolvedListeningMapProjection(itemId: itemId),
              let proposals = try? store.loadPortableListeningMapProposals(itemId: itemId),
              let proposal = proposals.first(where: { $0.id == projection.proposalId }),
              preparingLocalAudioMapItems.insert(itemId).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparingLocalAudioMapItems.remove(itemId) }
            do {
                for scene in proposal.scenes where scene.eligibility == .eligible {
                    try Task.checkCancellation()
                    guard try await self.prepareSummaryBridgeAsset(
                        itemId: itemId, proposalId: proposal.id, scene: scene, store: store
                    ) != nil else {
                        throw SessionKitError.persistenceFailed("Summary audio was not prepared")
                    }
                    self.updateSkimAvailability()
                }
                self.diagnostics["localAudioSkim:\(itemId)"] = "ready"
            } catch {
                self.diagnostics["localAudioSkim:\(itemId)"] = "failed:\(error.localizedDescription)"
                self.reportWarning("Some Skim summaries are not ready. Reopen the item to retry, or reimport the package to restore its supplied voices.")
            }
        }
    }

    private func installEmbeddedItem(
        from contents: VerifiedSpokenMarginsPackage,
        store: SQLiteSessionStore
    ) throws -> String {
        guard contents.manifest.itemTransport.kind == .embeddedText,
              let artifactID = contents.manifest.itemTransport.embeddedArtifactId,
              let embedded = contents.embeddedTextItems.first(where: { $0.id == artifactID }),
              let digest = contents.manifest.contentDigest else {
            throw SessionKitError.persistenceFailed("shared_embedded_item_is_unavailable")
        }
        let itemID = "item-shared-\(digest.prefix(20))"
        let item = Item(
            id: itemID,
            title: contents.manifest.item.title,
            mediaType: "text",
            text: embedded.text,
            externalReference: "shared-package:\(contents.manifest.packageId)",
            status: "ready",
            externalReferenceType: "spoken_margins_package"
        )
        try store.seed(item: item)
        return itemID
    }

    private func acquirePodcastForImportedPackage(_ item: SharedItemIdentity) async throws -> String {
        guard let canonicalURL = item.canonicalURL,
              normalizedSharingURL(canonicalURL) != nil else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_has_no_reference")
        }
        let request = LinkResolutionRequest(
            id: "shared-package-\(UUID().uuidString)",
            inputURL: canonicalURL,
            sourceSurface: "spoken_margins_package",
            createdAt: Date()
        )
        var result: LinkResolutionResult
        do {
            if let sourceLinkResolver {
                result = try sourceLinkResolver.resolve(request)
            } else {
                result = try await PublicPodcastLinkResolver().resolveAsync(request)
            }
        } catch {
            // Keep the existing resolver path first. Some publisher pages reject
            // automated requests even when the packet has the exact enclosure.
            // In that case, use its reference through the same source persistence
            // path; anchor placement still needs recipient evidence.
            guard let packageResult = packagePodcastLinkResolution(item: item, request: request) else {
                throw error
            }
            diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_resolution_failure"
            result = packageResult
        }
        if result.status == .needsReview {
            // Enclosures match by the file behind their tracking redirects. Duration only breaks ties: shows with
            // dynamic ads report different lengths for the same episode.
            let exactEnclosureMatches = result.candidates.filter {
                PodcastEnclosureIdentity.sameFile($0.audioURL, item.enclosureURL)
            }
            let titleMatches = result.candidates.filter {
                $0.audioURL != nil
                    && $0.title.compare(item.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let titleDurationMatches = titleMatches.filter { durationIsCompatible($0.durationMs, item.durationMs) }
            let selected = exactEnclosureMatches.count == 1 ? exactEnclosureMatches.first
                : titleMatches.count == 1 ? titleMatches.first
                : titleDurationMatches.count == 1 ? titleDurationMatches.first
                : nil
            if let selected {
                result.status = .playable
                result.selectedCandidate = selected
            } else if !result.candidates.contains(where: { $0.audioURL != nil }),
                      let packageResult = packagePodcastLinkResolution(item: item, request: request) {
                // The lookup found the page but no audio at all, so there is nothing to confuse the packet's own
                // enclosure with. Placement still needs recipient evidence.
                diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_lookup_without_audio"
                result = packageResult
            } else {
                throw SessionKitError.persistenceFailed("shared_podcast_item_is_ambiguous")
            }
        }
        guard result.status == .playable,
              let importedItem = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_not_created")
        }
        return importedItem.id
    }

    private func packagePodcastLinkResolution(
        item: SharedItemIdentity,
        request: LinkResolutionRequest
    ) -> LinkResolutionResult? {
        guard item.itemType == .podcast,
              let canonicalURL = item.canonicalURL,
              normalizedSharingURL(canonicalURL) != nil,
              let enclosureURL = item.enclosureURL,
              normalizedSharingURL(enclosureURL) != nil,
              !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sourceLink = SourceLink(
            url: canonicalURL, provider: "shared_package", title: item.title,
            role: "package_reference"
        )
        let candidate = LinkResolutionCandidate(
            sourceLink: sourceLink,
            title: item.title,
            showTitle: item.showTitle,
            durationMs: item.durationMs,
            publishedAt: item.publishedAt,
            audioURL: enclosureURL,
            confidence: 1
        )
        return LinkResolutionResult(
            requestId: request.id,
            status: .playable,
            originalLink: sourceLink,
            selectedCandidate: candidate,
            candidates: [candidate]
        )
    }

    private func importedLayerHasValidItemAssociation(
        _ layer: ImportedCommentaryLayer,
        store: SQLiteSessionStore
    ) -> Bool {
        guard layer.sourceResolutionStatus != .wrongSource,
              let itemId = layer.itemId,
              let item = try? store.loadItem(id: itemId) else { return false }
        guard item.deletedAt == nil else { return false }
        return ImportedItemResolver.canRepresentSameWork(
            layer.itemIdentity,
            localSharedItemIdentity(for: item)
        )
    }

    private func repairImportedLayerAssociation(
        _ existing: ImportedCommentaryLayer,
        contents: VerifiedSpokenMarginsPackage,
        itemId: String?,
        localItem: SharedItemIdentity?,
        itemText: String?,
        store: SQLiteSessionStore
    ) throws {
        guard let itemId,
              let localItem,
              let commentary = contents.commentaryLayers.first else {
            throw SessionKitError.persistenceFailed("shared_package_repair_item_is_unavailable")
        }
        let resolution = ImportedItemResolver.resolve(
            item: contents.manifest.item,
            interjections: commentary.interjections,
            against: localItem,
            itemText: itemText
        )
        guard resolution.status != .wrongSource else {
            throw SessionKitError.persistenceFailed("shared_package_repair_source_did_not_match")
        }
        var layer = existing
        layer.itemId = itemId
        layer.sourceResolutionStatus = resolution.status
        try store.saveImportedCommentaryLayer(layer)
        for var interjection in try store.loadImportedCommentaryInterjections(layerId: layer.id) {
            interjection.resolution = resolution.anchorsByPackageScopedId[interjection.packageScopedId]
                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
            try store.saveImportedCommentaryInterjection(interjection)
        }
        diagnostics["lastSpokenMarginsPackageRepair"] = "reassociated:\(layer.id):\(itemId)"
    }

    private func matchingItemID(
        for itemIdentity: SharedItemIdentity,
        store: SQLiteSessionStore
    ) throws -> String? {
        if shouldForceFirstSharedSourceMissForUITesting {
            shouldForceFirstSharedSourceMissForUITesting = false
            diagnostics["uiTestSharedSourceMiss"] = "forced_once"
            return nil
        }
        let matches = try store.listItems().filter { item in
            ImportedItemResolver.canRepresentSameWork(itemIdentity, localSharedItemIdentity(for: item))
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    func localSharedItemIdentity(for item: Item) -> SharedItemIdentity {
        SharedItemIdentityBuilder.localIdentity(for: item, localAudioDigest: localAudiobookDigest(for: item))
    }

    private func localAudiobookDigest(for item: Item) -> String? {
        guard item.mediaType == "audiobook" else { return nil }
        return (try? store?.loadOwnedOfflineAssets())?.first(where: {
            $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid
        })?.checksumSHA256
    }

    private func normalizedSharingURL(_ value: String?) -> String? {
        SharedItemIdentityBuilder.normalizedSharingURL(value)
    }

    private func durationIsCompatible(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= max(2_000, Int((Double(rhs) * 0.005).rounded()))
    }

    func handleIncomingURL(_ url: URL) {
        if let marginLink = MarginDeepLink(url: url) { openMargin(marginLink); return }
        if url.isFileURL, url.pathExtension.lowercased() == "json" {
            importListeningEditionFile(url); return
        }
        if url.scheme == "spokenmargins", url.host == "listening-edition" {
            do {
                let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                importListeningEditionFile(try ListeningEditionStore.stagedFile(id: id))
            } catch { reportFailure(error, context: "Listening edition handoff failed") }
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == SpokenMarginsPackageArchive.fileExtension {
            stageSpokenMarginsPackageImport(from: url)
            return
        }
        if url.scheme == Gate5BrowserTextHandoffURL.scheme, url.host == "open" {
            screen = hasActiveSession ? .playback : .home
            return
        }
        if SourceLinkHandoffURL.isSourceLinkURL(url) {
            do {
                if let payloadID = SourceLinkHandoffURL.payloadID(from: url) {
                    let handoffStore = try resolvedSourceLinkHandoffStore()
                    _ = try SourceLinkHandoffURL.handoff(from: url, store: handoffStore)
                    diagnostics["lastSourceLinkPayloadCleanup"] = "queued:\(payloadID)"
                    importPendingSourceLinkHandoffs()
                } else if let handoff = SourceLinkHandoffURL.handoff(from: url) {
                    if sourceLinkResolver == nil {
                        Task { @MainActor in
                            await importSourceLinkAsync(handoff)
                        }
                    } else {
                        importSourceLink(handoff)
                    }
                } else {
                    reportFailure("Unsupported source link URL.")
                }
            } catch SourceLinkHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastSourceLinkPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Source link import failed")
            }
            return
        }
        guard !Gate5BrowserTextHandoffURL.isBrowserTextURL(url) else {
            do {
                if let payloadID = Gate5BrowserTextHandoffURL.payloadID(from: url) {
                    let handoffStore = try resolvedBrowserTextHandoffStore()
                    let handoff = try Gate5BrowserTextHandoffURL.handoff(from: url, store: handoffStore)
                    if hasActiveSession {
                        try importBrowserTextInBackground(handoff)
                        try? handoffStore.deletePayload(payloadID: payloadID)
                        diagnostics["lastBrowserTextPayloadCleanup"] = "imported_without_session_replacement"
                    } else if importBrowserText(handoff) {
                        try? handoffStore.deletePayload(payloadID: payloadID)
                    }
                } else if let handoff = Gate5BrowserTextHandoffURL.handoff(from: url) {
                    importBrowserText(handoff)
                } else {
                    reportFailure("Unsupported browser text URL.")
                }
            } catch Gate5BrowserTextHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastBrowserTextPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Browser text import failed")
            }
            return
        }
        handleGate2CompactURL(url)
    }

    var exportSourceTextAvailable: Bool {
        !selectedItem.isNativeAudio
    }

    func activateListeningEditionAudio(itemId: String, timeline: TranscriptTimeline) {
        guard let edition = try? ListeningEditionStore.application().load(itemID: itemId), let store else { return }
        do {
            let (proposal, projection) = try edition.audioMap(timeline: timeline)
            try store.savePortableListeningMapProposal(proposal, itemId: itemId)
            try store.saveResolvedListeningMapProjection(projection)
            if selectedItem.id == itemId { refreshSelectedItem() }
            prepareImportedLocalAudioBridges(itemId: itemId)
            Task { await ListeningReadyNotifications.notify(itemID: itemId, title: edition.title, revision: edition.revision) }
        } catch { diagnostics["listeningEditionAudio"] = "not_ready" }
    }

    // MARK: Portable listening editions and personal knowledge output
    func importListeningEditionData(_ data: Data, replaceMap: Bool = false) {
        do {
            try performListeningEditionImport(data, replaceMap: replaceMap)
        } catch { reportFailure(error, context: "Listening edition import failed") }
    }

    func importListeningEditionDataForShortcut(_ data: Data) throws {
        try performListeningEditionImport(data, replaceMap: false)
    }

    private func performListeningEditionImport(_ data: Data, replaceMap: Bool) throws {
        guard !snapshot.isRecording else { throw EditionError.invalid("Finish recording before importing a listening edition.") }
        let edition = try ListeningEdition.decode(data)
        let editions = try ListeningEditionStore.application()
        if let previous = try editions.load(itemID: edition.itemID), previous != edition, !replaceMap {
            throw EditionError.invalid("This source already has a different Listening Map. Use Import Listening Edition in Settings to preview and explicitly replace it.")
        }
        let store = try requireStore()
        // Stable source identity preserves every existing session and Margin on retry.
        if (try? store.loadItem(id: edition.itemID)) == nil {
            try store.saveItem(Item(id: edition.itemID, title: edition.title, mediaType: "text", text: edition.text,
                                   externalReference: edition.sourceURL, status: "ready", externalReferenceType: "url", createdAt: Date()))
        }
        if snapshot.itemId == edition.itemID, snapshot.status.isPlaybackActive {
            throw EditionError.invalid("Pause playback before importing a map for the current item.")
        }
        try editions.save(edition)
        if let engine { snapshot = try engine.attachListeningMap(edition.listeningMap()) }
        else { try store.saveListeningMap(edition.listeningMap()) }
        if let timeline = try store.loadTranscriptTimeline(itemId: edition.itemID)?.timeline {
            activateListeningEditionAudio(itemId: edition.itemID, timeline: timeline)
        }
        activeItemId = edition.itemID
        libraryItems = try loadLibraryRows(store: store)
        refreshSelectedItem()
        screen = .item
        scheduleTextAudioPrewarmIfNeeded(itemId: edition.itemID)
        reportConfirmation("Imported item and Listening Map. Audio prepares separately; playback has not started.")
    }

    func importListeningEditionFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8_000_000 else { throw EditionError.invalid("Listening edition exceeds 8 MB.") }
            importListeningEditionData(try Data(contentsOf: url))
        } catch { reportFailure(error, context: "Listening edition file could not be opened") }
    }

    func importReadLaterDocument(_ document: ReadLaterDocument) {
        guard !isImportingReadLater else { return }
        isImportingReadLater = true
        Task {
            defer { isImportingReadLater = false }
            do {
                if let html = document.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let handoff = Self.sanitizedBrowserTextHandoff(BrowserTextHandoff(
                        captureMode: .readablePage,
                        source: BrowserTextSource(url: document.url, title: document.title), text: html,
                        contentFormat: .plainText
                    ))
                    let store = try requireStore()
                    let id = "read-later-" + ListeningEdition.digest(document.url + "\n" + handoff.text)
                    if (try? store.loadItem(id: id)) != nil {
                        reportConfirmation("This article is already in your Library.")
                        return
                    }
                    var stable = handoff; stable.itemId = id
                    try importBrowserTextInBackground(stable)
                    reportConfirmation("Added article. Your reading service has not been changed.")
                } else {
                    // URL-only services use the existing local readable-page importer,
                    // including its visible unsupported/paywall failure behavior.
                    guard let url = URL(string: document.url) else { throw EditionError.invalid("Invalid article URL.") }
                    var handoff = try await readablePageExtractor.extract(url: url)
                    let id = "read-later-" + ListeningEdition.digest(document.url + "\n" + handoff.text)
                    let store = try requireStore()
                    if (try? store.loadItem(id: id)) != nil {
                        reportConfirmation("This article is already in your Library."); return
                    }
                    handoff.itemId = id
                    try importBrowserTextInBackground(handoff)
                    reportConfirmation("Added article from its original website.")
                }
            } catch { reportFailure(error, context: "Article import failed") }
        }
    }

    func automaticMarginOutputChanged() {
        UserDefaults.standard.set(automaticMarginOutputEnabled, forKey: "automaticMarginOutputEnabled")
        if automaticMarginOutputEnabled { marginNotesDelivery.start() }
        else { marginNotesDelivery.stop(); marginOutputStatus = "Automatic delivery is off. Exported files remain in your folder." }
    }

    func testMarginOutput() {
        Task {
            do {
                guard let folder = resolvedBatchExportFolderURL() else { throw EditionError.invalid("Choose an output folder first.") }
                marginOutputStatus = try await marginNotesDelivery.sendTestNote(to: folder, destinationID: marginOutputDestinationID)
            } catch { marginOutputStatus = error.localizedDescription }
        }
    }

    private var marginOutputDestinationID: String {
        UserDefaults.standard.string(forKey: "marginOutputDestinationID") ?? "initial"
    }

    func marginNotesTarget() throws -> MarginNotesDelivery.Target {
        guard let store, let folder = resolvedBatchExportFolderURL() else { throw EditionError.invalid("Choose or reselect an output folder. Your Margins remain safely in the Library.") }
        return .init(store: store, folder: folder, destinationID: marginOutputDestinationID)
    }

    func recordAutomaticMarginGather(ms: Int, sessions: Int, notes: Int) {
        automaticMarginGatherMaxMs = max(automaticMarginGatherMaxMs, ms)
        diagnostics["automaticMarginGather"] = "background;lastMs=\(ms);maxMs=\(automaticMarginGatherMaxMs);sessions=\(sessions);notes=\(notes)"
        // The always-on log keeps 300 events; only slow passes are worth one. The work is off the main actor now,
        // so a slow pass no longer freezes the UI; the event stays to show the cost.
        if ms >= 500 {
            recordDeveloperDiagnostic("marginOutput.gather", ["ms": String(ms), "sessions": String(sessions), "notes": String(notes)])
        }
    }

    func deliverAutomaticMargins() async { await marginNotesDelivery.pass() }

    private func refreshBatchExportRows(store: SQLiteSessionStore) throws {
        let itemsById = Dictionary(uniqueKeysWithValues: try store.listItems().map { ($0.id, $0) })
        batchExportRows = try store.loadSessions().compactMap { session in
            guard let item = itemsById[session.itemId] else { return nil }
            let interjectionCount = try store.loadInterjections(sessionId: session.id)
                .filter { $0.status == "active" }
                .count
            return BatchSessionExportRow(
                session: session,
                itemTitle: item.title,
                interjectionCount: interjectionCount
            )
        }
        let availableIds = Set(batchExportRows.map(\.id))
        selectedBatchExportSessionIds.formIntersection(availableIds)
    }

    private func resolvedSourceLinkHandoffStore() throws -> SourceLinkHandoffStore {
        if let sourceLinkHandoffStore {
            return sourceLinkHandoffStore
        }
        return try SourceLinkHandoffStore.appGroup()
    }

    private func resolvedBrowserTextHandoffStore() throws -> Gate5BrowserTextHandoffStore {
        if let browserTextHandoffStore {
            return browserTextHandoffStore
        }
        return try Gate5BrowserTextHandoffStore.appGroup()
    }

    private func sourceLinkFailureMessage(status: String?, reason: String?, provider: String?) -> String {
        switch reason {
        case "spotify_audio_requires_provider_playback":
            if provider == "spotify" {
                return "Spoken Margins could not find a public audio file for this Spotify episode."
            }
            return "This provider did not expose a public audio file that Spoken Margins can play yet."
        case "spotify_metadata_unavailable":
            return "Spotify did not return enough episode metadata to search for a public copy."
        case "spotify_specific_episode_required":
            return "Open the specific episode in Spotify, tap Share, and send its episode link. Show or podcast-page links do not identify one episode."
        case "spotify_episode_not_found_on_apple":
            return "I could not find a confident Apple Podcasts match for this Spotify episode. It may be Spotify-only."
        case "spotify_episode_match_ambiguous":
            return "I found more than one Apple Podcasts episode with this title, so I did not risk importing the wrong one. Try sharing the specific Apple Podcasts episode or its RSS link."
        case "apple_episode_id_missing":
            return "That Apple Podcasts link did not identify a specific episode."
        case "apple_lookup_empty":
            return "Apple Podcasts did not return this episode from lookup, and I could not find a public audio stream on the Apple page."
        case "apple_audio_enclosure_not_found":
            return "Apple Podcasts did not expose a playable public audio stream for that episode."
        case "audio_enclosure_not_found":
            return "I found the page or feed, but not a playable podcast/audio file."
        case "rss_episode_ambiguous":
            return "I found the feed, but could not identify one episode to play."
        case "unsupported_link_type":
            return "That link is not a supported public podcast, RSS feed, or direct audio file."
        case "apple_lookup_failed":
            return "Apple Podcasts did not return a playable public audio file for that episode."
        case .some(let message):
            return message
        case .none:
            if status == LinkResolutionStatus.unsupported.rawValue {
                return "That link is not playable in Spoken Margins yet."
            }
            return "Source link needs review before it can be played."
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url).first
    }

    private func scheduleSourceTranscriptImportIfAvailable(_ links: [SourceTranscriptLink], itemId: String) {
        guard !links.isEmpty else {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "no_links"
            return
        }
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.transcriptId == nil else { return }
        let sortedLinks = Self.prioritizedTranscriptLinks(links)
        diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "scheduled:\(sortedLinks.count)"
        diagnostics["sourceTranscriptionStatus"] = "downloading"
        if activeItemId == itemId {
            sourceTranscriptStatus = "downloading"
            snapshot.sourceTranscriptStatus = "downloading"
        }
        Task { [weak self, itemId, sortedLinks, durationMs = item.media?.durationMs] in
            guard let self else { return }
            var lastFailure = ""
            for link in sortedLinks {
                do {
                    let data = try await Self.fetchTranscriptLink(link)
                    if let timeline = try Self.transcriptTimeline(from: data, link: link, itemId: itemId, durationMs: durationMs),
                       !timeline.segments.isEmpty {
                        await MainActor.run {
                            self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "attached:\(link.type)"
                            self.attachSourceTranscriptTimeline(timeline, itemId: itemId)
                        }
                        return
                    }
                    lastFailure = "empty:\(link.type)"
                } catch {
                    lastFailure = "\(link.type):\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "unavailable:\(lastFailure)"
                self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                if self.activeItemId == itemId {
                    self.sourceTranscriptStatus = "unavailable"
                    self.snapshot.sourceTranscriptStatus = "unavailable"
                }
            }
        }
    }

    private static func prioritizedTranscriptLinks(_ links: [SourceTranscriptLink]) -> [SourceTranscriptLink] {
        links.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = transcriptLinkRank(lhs.element)
                let rhsRank = transcriptLinkRank(rhs.element)
                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }
                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func transcriptLinkRank(_ link: SourceTranscriptLink) -> Int {
        let value = "\(link.type) \(link.url) \(link.rel ?? "")".lowercased()
        if value.contains("vtt") || value.contains("webvtt") { return 0 }
        if value.contains("srt") || value.contains("subrip") { return 1 }
        if value.contains("json") { return 2 }
        if value.contains("plain") || value.contains(".txt") { return 3 }
        if value.contains("html") || value.contains(".htm") { return 4 }
        return 5
    }

    private static func fetchTranscriptLink(_ link: SourceTranscriptLink) async throws -> Data {
        guard let url = URL(string: link.url),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw SessionKitError.persistenceFailed("source_transcript_url_unsupported")
        }
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func transcriptTimeline(from data: Data, link: SourceTranscriptLink, itemId: String, durationMs: Int?) throws -> TranscriptTimeline? {
        let type = "\(link.type) \(link.url)".lowercased()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        if type.contains("vtt") || type.contains("srt") {
            return cueTranscriptTimeline(from: text, itemId: itemId, durationMs: durationMs)
        }
        if type.contains("json") {
            return jsonTranscriptTimeline(from: data, itemId: itemId, durationMs: durationMs)
        }
        let cleaned = type.contains("html") ? stripHTML(text) : text
        let normalized = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let endMs = max(1, durationMs ?? 1)
        return TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "transcript-\(itemId)-plain-0001",
                    startMs: 0,
                    endMs: endMs,
                    text: normalized
                )
            ],
            chapters: [],
            durationMs: durationMs ?? endMs
        )
    }

    private static func cueTranscriptTimeline(from text: String, itemId: String, durationMs: Int?) -> TranscriptTimeline {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var segments: [MediaTimelineSegment] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let startMs = parseCueTime(parts[0]),
                  let endMs = parseCueTime(parts[1]) else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-cue-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: body
            ))
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func jsonTranscriptTimeline(from data: Data, itemId: String, durationMs: Int?) -> TranscriptTimeline? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            entries = array
        } else if let dictionary = object as? [String: Any],
                  let nested = (dictionary["segments"] ?? dictionary["transcripts"] ?? dictionary["captions"]) as? [[String: Any]] {
            entries = nested
        } else if let dictionary = object as? [String: Any],
                  let text = dictionary["text"] as? String {
            let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let endMs = max(1, durationMs ?? 1)
            return TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "transcript-\(itemId)-json-0001", startMs: 0, endMs: endMs, text: normalized)],
                chapters: [],
                durationMs: durationMs ?? endMs
            )
        } else {
            return nil
        }
        var segments: [MediaTimelineSegment] = []
        for entry in entries {
            let body = (entry["text"] ?? entry["body"] ?? entry["caption"]) as? String ?? ""
            let text = body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = jsonTimeMs(entry["start"] ?? entry["startTime"] ?? entry["start_ms"] ?? entry["offset"]) ?? 0
            let explicitEndMs = jsonTimeMs(entry["end"] ?? entry["endTime"] ?? entry["end_ms"])
            let duration = jsonTimeMs(entry["duration"] ?? entry["durationMs"] ?? entry["duration_ms"])
            let endMs = explicitEndMs ?? duration.map { startMs + $0 } ?? max(startMs + 1, durationMs ?? startMs + 1)
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-json-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: text
            ))
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func parseCueTime(_ raw: String) -> Int? {
        let value = raw
            .split(separator: " ")
            .first?
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return Int(((hours * 3600) + (minutes * 60) + seconds) * 1000)
    }

    private static func jsonTimeMs(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        case let string as String:
            if string.contains(":") {
                return parseCueTime(string)
            }
            guard let double = Double(string) else { return nil }
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        default:
            return nil
        }
    }

    static func sanitizedBrowserTextHandoff(_ handoff: BrowserTextHandoff) -> BrowserTextHandoff {
        guard handoff.captureMode == .readablePage,
              handoff.text.range(of: #"<[^>]+>"#, options: .regularExpression) != nil else {
            return handoff
        }
        var sanitized = handoff
        sanitized.text = handoff.contentFormat == .markdown
            ? stripEmbeddedHTMLPreservingMarkdown(handoff.text)
            : stripHTML(handoff.text)
        sanitized.text = sanitized.text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    private static func stripEmbeddedHTMLPreservingMarkdown(_ markdown: String) -> String {
        var result = markdown
            .replacingOccurrences(
                of: #"<\s*(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b[^>]*>[\s\S]*?<\s*/\s*\1\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<\s*(source|img)\b[^>]*>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )

        for level in 1...6 {
            result = result
                .replacingOccurrences(
                    of: #"<\s*h\#(level)\b[^>]*>"#,
                    with: "\n\(String(repeating: "#", count: level)) ",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"<\s*/\s*h\#(level)\s*>"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                )
        }

        return result
            .replacingOccurrences(
                of: #"</?(p|div|section|article|li|br)\b[^>]*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<video[\s\S]*?</video>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<source[^>]*>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</?(p|div|section|article|h[1-6]|li|br)[^>]*>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    func scheduleFullSourceTranscriptionForListeningMap(for item: Item, localSourceURL: URL? = nil) {
        guard item.transcriptId == nil,
              let sourceURLString = item.media?.url,
              let canonicalURL = URL(string: sourceURLString) else {
            return
        }
        guard pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        let sourceURL = localSourceURL
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: item.id)
            ?? canonicalURL
        guard sourceURL.isFileURL else {
            pendingFullSourceTranscriptionItemIds.remove(item.id)
            diagnostics["sourceTranscriptionStatus"] = "waiting_for_local_audio"
            return
        }
        diagnostics["sourceTranscriptionStatus"] = "transcribing"
        if activeItemId == item.id {
            sourceTranscriptStatus = "transcribing"
            snapshot.sourceTranscriptStatus = "transcribing"
            statusMessage = "Transcribing source audio..."
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: sourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                await MainActor.run {
                    self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                    self.attachSourceTranscriptTimeline(timeline, itemId: item.id)
                }
            } catch {
                await MainActor.run {
                    self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                    self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                    self.diagnostics["sourceTranscriptionError"] = String(describing: error)
                    if self.activeItemId == item.id {
                        self.sourceTranscriptStatus = "unavailable"
                        self.snapshot.sourceTranscriptStatus = "unavailable"
                    }
                    if self.pendingMapGenerationItemId == item.id {
                        self.pendingMapGenerationItemId = nil
                    }
                    if self.activeItemId == item.id, self.lastError == nil {
                        self.statusMessage = "Audio ready. Source transcript and Listening Map are unavailable; notes will use timestamp context."
                    }
                }
            }
        }
    }

    func attachSourceTranscriptTimeline(_ timeline: TranscriptTimeline, itemId: String) {
        let shouldGeneratePendingMap = pendingMapGenerationItemId == itemId
        run { engine in
            snapshot = try engine.attachTranscriptTimeline(itemId: itemId, timeline: timeline)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                // Transcript imports can finish long after a shared podcast was
                // added. They must never retarget the playback screen away from
                // the item/session that is still active.
                if activeItemId == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            diagnostics["sourceTranscriptionStatus"] = "complete"
            diagnostics["sourceTranscriptionItem"] = itemId
            if activeItemId == itemId {
                sourceTranscriptStatus = "ready"
                snapshot.sourceTranscriptStatus = "ready"
            }
        }
        if shouldGeneratePendingMap {
            pendingMapGenerationItemId = nil
            generateListeningMap()
        }
        retrySourceWindowContexts(itemId: itemId)
        if let localURL = importedPodcastRecipientLocalURLs[itemId]
            ?? podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
            resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
        }
    }

    func prepareExportShareInterjections() {
        do {
            let store = try requireStore()
            guard let exportSessionId, let session = try store.loadSession(id: exportSessionId) else {
                throw SessionKitError.persistenceFailed("export_session_missing")
            }
            let candidates = try store.loadInterjections(sessionId: session.id)
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            prepareShareInterjections(candidates: candidates)
        } catch { reportFailure(error, context: "Prepare session sharing failed") }
    }

    func openMarginItemExport(itemID: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        do {
            selectedItem = try loadItemDetail(id: itemID, store: requireStore())
            let sessionID = selectedItem.sessionRows.first { $0.interjectionCount > 0 }?.id
            openExport(sessionId: sessionID)
        } catch { reportFailure(error, context: "Open item export failed") }
    }

    func prepareShareInterjections() {
        prepareShareInterjections(candidates: selectedItem.interjections)
    }

    private func prepareShareInterjections(candidates source: [Interjection]) {
        cancelBulkSharePreparation()
        let candidates = source.filter {
            $0.status == "active" && $0.targetType == .item
        }
        guard !candidates.isEmpty else {
            reportFailure("Record at least one Margin on this item before sharing.")
            return
        }
        let hasStarredCandidates = candidates.contains { $0.isStarredForSharing == true }
        sharingState = InterjectionSharingState(isPreparing: true)
        sharingState.draftFilter = hasStarredCandidates ? .starred : .all
        isSharingInterjectionsPresented = true
        if let item = try? requireStore().loadItem(id: selectedItem.id) {
            let reference = secureSharedItemURL(for: item)
            sharingState.itemReferenceURL = reference
            sharingState.isAppAuthoredItem = item.id == Self.welcomeSampleItemId
            sharingState.canEmbedLinklessItem = reference == nil
                && sharedItemType(for: item) != .podcast
                && !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            sharingState.confirmsPrivateSharingRights = sharingState.isAppAuthoredItem
        }
        sharingState.drafts = candidates.map { interjection in
            let transcript = interjection.cleanedTranscript
                ?? interjection.transcript
                ?? interjection.displayText
                ?? ""
            let hasAudio = interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)) != nil
            let context = BoundedAnchorContext.select(
                before: interjection.anchor.anchorBefore,
                after: interjection.anchor.anchorAfter
            )
            return ShareInterjectionDraft(
                interjection: interjection,
                isIncluded: !hasStarredCandidates || interjection.isStarredForSharing == true,
                approvedTranscript: transcript,
                representationChoice: hasAudio ? .original : .textOnly,
                warning: SharedMarginTextRequirement.reviewWarning(for: transcript) ?? shareAnchorWarning(for: interjection),
                anchorBefore: context.before,
                anchorAfter: context.after
            )
        }
        sharingState.isPreparing = false
    }

    var bulkSharePreparationEligibleCount: Int {
        sharingState.drafts.filter(isEligibleForBulkSharePreparation).count
    }

    func prepareAllIncludedShareDrafts() {
        guard !sharingState.isBulkPreparing else { return }
        let draftIDs = sharingState.drafts
            .filter(isEligibleForBulkSharePreparation)
            .map(\.id)
        guard !draftIDs.isEmpty else { return }

        bulkSharePreparationGeneration += 1
        let generation = bulkSharePreparationGeneration
        sharingState.isBulkPreparing = true
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = draftIDs.count
        sharingState.bulkPreparationFailureCount = 0
        sharingState.errorMessage = nil
        diagnostics["bulkSharePreparation"] = "started:total=\(draftIDs.count)"

        bulkSharePreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for draftID in draftIDs {
                guard !Task.isCancelled,
                      self.bulkSharePreparationGeneration == generation else { return }
                let prepared = await self.prepareShareDraftForBulk(
                    draftID,
                    generation: generation
                )
                guard !Task.isCancelled,
                      self.bulkSharePreparationGeneration == generation else { return }
                self.sharingState.bulkPreparationCompleted += 1
                if !prepared {
                    self.sharingState.bulkPreparationFailureCount += 1
                }
            }
            guard self.bulkSharePreparationGeneration == generation else { return }
            self.sharingState.isBulkPreparing = false
            self.bulkSharePreparationTask = nil
            self.diagnostics["bulkSharePreparation"] = [
                "complete",
                "prepared=\(self.sharingState.bulkPreparationCompleted)",
                "fallbacks=\(self.sharingState.bulkPreparationFailureCount)"
            ].joined(separator: ";")
        }
    }

    func cancelBulkSharePreparation() {
        guard sharingState.isBulkPreparing || bulkSharePreparationTask != nil else { return }
        bulkSharePreparationGeneration += 1
        bulkSharePreparationTask?.cancel()
        bulkSharePreparationTask = nil
        sharingState.isBulkPreparing = false
        for index in sharingState.drafts.indices {
            let wasInFlight = sharingState.drafts[index].isAnalyzingPauses
                || sharingState.drafts[index].isPreparingCleanup
            sharingState.drafts[index].isAnalyzingPauses = false
            sharingState.drafts[index].isPreparingCleanup = false
            if wasInFlight,
               sharingState.drafts[index].currentEditState.automaticCleanupEnabled,
               sharingState.drafts[index].canUndoEdit {
                sharingState.drafts[index].editHistoryIndex -= 1
                applyShareEditState(at: index, renderCleanedAudio: false)
            }
        }
        diagnostics["bulkSharePreparation"] = [
            "cancelled",
            "prepared=\(sharingState.bulkPreparationCompleted)",
            "total=\(sharingState.bulkPreparationTotal)"
        ].joined(separator: ";")
    }

    private func isEligibleForBulkSharePreparation(_ draft: ShareInterjectionDraft) -> Bool {
        draft.isIncluded
            && draft.interjection.alignedTranscript != nil
            && !draft.currentEditState.automaticCleanupEnabled
    }

    private func prepareShareDraftForBulk(
        _ id: String,
        generation: Int
    ) async -> Bool {
        guard let initialIndex = sharingState.drafts.firstIndex(where: { $0.id == id }),
              let aligned = sharingState.drafts[initialIndex].interjection.alignedTranscript else {
            return false
        }
        sharingState.drafts[initialIndex].preparationMessage = nil
        recordShareEdit(for: id, renderCleanedAudio: false) {
            $0.automaticCleanupEnabled = true
        }
        sharingState.automaticallyCleanedDraftIDs.insert(id)

        guard let analysisIndex = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let audioPath = sharingState.drafts[analysisIndex].interjection.audioPath
        let sourceURL = audioPath.flatMap(resolvedInterjectionAudioURL(for:))
        var analysisFailure: String?
        if let sourceURL {
            sharingState.drafts[analysisIndex].isAnalyzingPauses = true
            let analyzer = shareMarginSilenceAnalysisHandler
            let analysis = await Task.detached {
                do {
                    return (try analyzer(sourceURL, aligned), nil as String?)
                } catch {
                    return ([], error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled,
                  bulkSharePreparationGeneration == generation,
                  let current = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
                return false
            }
            sharingState.drafts[current].isAnalyzingPauses = false
            sharingState.drafts[current].acousticPauseDecisions = analysis.0
            analysisFailure = analysis.1
            applyShareEditState(at: current, renderCleanedAudio: false)
        } else if audioPath != nil {
            analysisFailure = "The saved voice recording is unavailable; reviewed text remains available."
        }

        guard !Task.isCancelled,
              bulkSharePreparationGeneration == generation else { return false }
        let rendered = await renderBulkCleanup(forShareDraft: id, generation: generation)
        guard bulkSharePreparationGeneration == generation,
              let finalIndex = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        if let analysisFailure {
            let analysisMessage =
                "Pause analysis was unavailable (\(analysisFailure)). Filler and manual text edits remain reviewable."
            if let renderMessage = sharingState.drafts[finalIndex].preparationMessage {
                sharingState.drafts[finalIndex].preparationMessage = "\(renderMessage) \(analysisMessage)"
            } else {
                sharingState.drafts[finalIndex].preparationMessage = analysisMessage
            }
        }
        return rendered && analysisFailure == nil
    }

    private func renderBulkCleanup(
        forShareDraft id: String,
        generation bulkGeneration: Int
    ) async -> Bool {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else {
            return false
        }
        guard let decisions = sharingState.drafts[index].cleanup?.decisions else {
            return true
        }
        guard let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath) else {
            sharingState.drafts[index].representationChoice = .textOnly
            sharingState.drafts[index].preparationMessage =
                "Cleaned voice could not be prepared because the saved recording is unavailable. Reviewed text remains available."
            return false
        }
        guard let root = try? applicationSupportDirectory()
            .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            sharingState.drafts[index].preparationMessage =
                "Cleaned voice storage is unavailable. Original voice and reviewed text remain available."
            return false
        }
        sharingState.drafts[index].renderGeneration += 1
        let renderGeneration = sharingState.drafts[index].renderGeneration
        sharingState.drafts[index].isPreparingCleanup = true
        let destination = root.appending(path: "cleaned-\(safePodcastEvidenceComponent(id)).m4a")
        let renderer = shareMarginAudioCleanupHandler
        let result: (duration: Int?, failure: String?)
        do {
            result = (try await renderer(sourceURL, destination, decisions), nil)
        } catch {
            result = (nil, error.localizedDescription)
        }
        guard !Task.isCancelled,
              bulkSharePreparationGeneration == bulkGeneration,
              let current = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[current].renderGeneration == renderGeneration else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        sharingState.drafts[current].isPreparingCleanup = false
        if let duration = result.duration {
            sharingState.drafts[current].cleanedAudioURL = destination
            sharingState.drafts[current].cleanedAudioDurationMs = duration
            sharingState.drafts[current].representationChoice = .cleaned
            return true
        }
        sharingState.drafts[current].cleanedAudioURL = nil
        sharingState.drafts[current].cleanedAudioDurationMs = nil
        sharingState.drafts[current].representationChoice =
            originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
        sharingState.drafts[current].preparationMessage =
            "Cleaned voice could not be prepared (\(result.failure ?? "unknown error")). Original voice or reviewed text remains available."
        return false
    }

    func setShareDraftIncluded(_ id: String, included: Bool) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].isIncluded = included
    }

    func setShareDraftsIncluded(_ ids: [String], included: Bool) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        for index in sharingState.drafts.indices where targetIDs.contains(sharingState.drafts[index].id) {
            sharingState.drafts[index].isIncluded = included
        }
    }

    func setShareAutoCleanSelectedEnabled(_ enabled: Bool) {
        ShareAutoCleanPreference.record(enabled: enabled)
        sharingState.needsAutoCleanDecision = false
        sharingState.autoCleanSelectedEnabled = enabled
        if enabled {
            prepareAllIncludedShareDrafts()
        } else {
            cancelBulkSharePreparation()
            undoAutomaticallyCleanedShareDrafts()
        }
    }

    func prepareAutomaticallyCleanedShareDraftsIfEnabled() {
        guard sharingState.autoCleanSelectedEnabled else { return }
        prepareAllIncludedShareDrafts()
    }

    private func undoAutomaticallyCleanedShareDrafts() {
        let draftIDs = sharingState.automaticallyCleanedDraftIDs
        for id in draftIDs {
            recordShareEdit(for: id, renderCleanedAudio: false) {
                $0.automaticCleanupEnabled = false
                $0.restoredAutomaticDecisionIds.removeAll()
            }
        }
        sharingState.automaticallyCleanedDraftIDs.removeAll()
        sharingState.bulkPreparationCompleted = 0
        sharingState.bulkPreparationTotal = 0
        sharingState.bulkPreparationFailureCount = 0
    }

    func setShareDraftRepresentation(_ id: String, choice: ShareMarginRepresentationChoice) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        if choice == .cleaned, sharingState.drafts[index].cleanedAudioURL == nil { return }
        if choice == .original, originalAudioURL(forShareDraft: id) == nil { return }
        sharingState.drafts[index].representationChoice = choice
    }

    func setShareDraftAnchorBefore(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].anchorBefore = String(value.suffix(BoundedAnchorContext.maximumCharactersPerSide))
    }

    func setShareDraftAnchorAfter(_ id: String, value: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.drafts[index].anchorAfter = String(value.prefix(BoundedAnchorContext.maximumCharactersPerSide))
    }

    func originalAudioURL(forShareDraft id: String) -> URL? {
        sharingState.drafts.first(where: { $0.id == id })?
            .interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:))
    }

    func prepareCleanup(forShareDraft id: String) {
        guard !sharingState.isBulkPreparing else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
            sharingState.drafts[index].preparationMessage = nil
        }
        recordShareEdit(for: id) { $0.automaticCleanupEnabled = true }
        analyzeAcousticPauses(forShareDraft: id)
    }

    func setCleanupDecision(draftID: String, decisionID: String, accepted: Bool) {
        recordShareEdit(for: draftID) { state in
            if accepted {
                state.restoredAutomaticDecisionIds.remove(decisionID)
            } else {
                state.restoredAutomaticDecisionIds.insert(decisionID)
            }
        }
    }

    func toggleShareDraftWord(draftID: String, segmentID: String) {
        guard let draft = sharingState.drafts.first(where: { $0.id == draftID }),
              let aligned = draft.interjection.alignedTranscript,
              let segment = aligned.segments.first(where: { $0.id == segmentID }) else { return }
        let overlappingAccepted = draft.cleanup?.decisions.filter {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? []
        recordShareEdit(for: draftID) { state in
            if state.manuallyDeletedSegmentIds.contains(segmentID) || !overlappingAccepted.isEmpty {
                state.manuallyDeletedSegmentIds.remove(segmentID)
                overlappingAccepted.forEach { state.restoredAutomaticDecisionIds.insert($0.id) }
            } else {
                state.manuallyDeletedSegmentIds.insert(segmentID)
            }
        }
    }

    func isShareDraftWordDeleted(draftID: String, segmentID: String) -> Bool {
        guard let draft = sharingState.drafts.first(where: { $0.id == draftID }),
              let segment = draft.interjection.alignedTranscript?.segments.first(where: { $0.id == segmentID }) else {
            return false
        }
        return draft.cleanup?.decisions.contains {
            $0.accepted && $0.kind != .longPause && $0.startMs < segment.endMs && $0.endMs > segment.startMs
        } ?? false
    }

    func undoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].canUndoEdit else { return }
        sharingState.drafts[index].editHistoryIndex -= 1
        applyShareEditState(at: index)
    }

    func redoShareDraftEdit(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].canRedoEdit else { return }
        sharingState.drafts[index].editHistoryIndex += 1
        applyShareEditState(at: index)
    }

    func restoreOriginalShareDraft(_ id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
        sharingState.automaticallyCleanedDraftIDs.remove(id)
        let interjection = sharingState.drafts[index].interjection
        sharingState.drafts[index].editHistory = [.original]
        sharingState.drafts[index].editHistoryIndex = 0
        sharingState.drafts[index].cleanup = nil
        sharingState.drafts[index].cleanedAudioURL = nil
        sharingState.drafts[index].cleanedAudioDurationMs = nil
        sharingState.drafts[index].isAnalyzingPauses = false
        sharingState.drafts[index].isPreparingCleanup = false
        sharingState.drafts[index].preparationMessage = nil
        sharingState.drafts[index].approvedTranscript = interjection.transcript ?? interjection.displayText ?? ""
        sharingState.drafts[index].representationChoice = originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
        sharingState.drafts[index].warning = SharedMarginTextRequirement.reviewWarning(for: sharingState.drafts[index].approvedTranscript) ?? shareAnchorWarning(for: interjection)
    }

    private func recordShareEdit(
        for id: String,
        renderCleanedAudio: Bool = true,
        mutate: (inout ShareMarginEditState) -> Void
    ) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].interjection.alignedTranscript != nil else { return }
        var state = sharingState.drafts[index].currentEditState
        mutate(&state)
        guard state != sharingState.drafts[index].currentEditState else { return }
        sharingState.drafts[index].editHistory = Array(
            sharingState.drafts[index].editHistory.prefix(sharingState.drafts[index].editHistoryIndex + 1)
        ) + [state]
        sharingState.drafts[index].editHistoryIndex += 1
        applyShareEditState(at: index, renderCleanedAudio: renderCleanedAudio)
    }

    private func applyShareEditState(at index: Int, renderCleanedAudio: Bool = true) {
        guard sharingState.drafts.indices.contains(index),
              let aligned = sharingState.drafts[index].interjection.alignedTranscript else { return }
        let state = sharingState.drafts[index].currentEditState
        let allAutomatic = DeterministicInterjectionCleanup.propose(aligned).decisions.map(\.id)
        var restored = state.restoredAutomaticDecisionIds
        if !state.automaticCleanupEnabled {
            restored.formUnion(allAutomatic)
            restored.formUnion(sharingState.drafts[index].acousticPauseDecisions.map(\.id))
        }
        let core = DeterministicInterjectionCleanup.propose(
            aligned,
            restoredDecisionIds: restored,
            manuallyDeletedSegmentIds: state.manuallyDeletedSegmentIds
        )
        let acoustic = sharingState.drafts[index].acousticPauseDecisions.map { decision in
            InterjectionCleanupDecision(
                id: decision.id,
                kind: decision.kind,
                startMs: decision.startMs,
                endMs: decision.endMs,
                originalText: decision.originalText,
                accepted: !restored.contains(decision.id)
            )
        }
        let visibleCoreDecisions = acoustic.isEmpty
            ? core.decisions
            : core.decisions.filter { $0.kind != .longPause }
        let hasEdits = visibleCoreDecisions.contains { $0.accepted } || acoustic.contains { $0.accepted }
        sharingState.drafts[index].cleanup = hasEdits
            ? InterjectionCleanupResult(
                policyVersion: core.policyVersion,
                cleanedTranscript: core.cleanedTranscript,
                decisions: (visibleCoreDecisions + acoustic).sorted { $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs }
            )
            : nil
        sharingState.drafts[index].approvedTranscript = hasEdits
            ? core.cleanedTranscript
            : (sharingState.drafts[index].interjection.transcript ?? sharingState.drafts[index].interjection.displayText ?? "")
        if hasEdits, renderCleanedAudio {
            renderCleanup(forShareDraft: sharingState.drafts[index].id)
        } else {
            sharingState.drafts[index].isPreparingCleanup = false
            sharingState.drafts[index].cleanedAudioURL = nil
            sharingState.drafts[index].cleanedAudioDurationMs = nil
            sharingState.drafts[index].representationChoice = originalAudioURL(forShareDraft: sharingState.drafts[index].id) == nil ? .textOnly : .original
        }
    }

    private func analyzeAcousticPauses(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              sharingState.drafts[index].acousticPauseDecisions.isEmpty,
              !sharingState.drafts[index].isAnalyzingPauses,
              let aligned = sharingState.drafts[index].interjection.alignedTranscript,
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath) else { return }
        sharingState.drafts[index].isAnalyzingPauses = true
        let analyzer = shareMarginSilenceAnalysisHandler
        Task.detached { [weak self] in
            let result: ([InterjectionCleanupDecision], String?)
            do {
                result = (try analyzer(sourceURL, aligned), nil)
            } catch {
                result = ([], error.localizedDescription)
            }
            await MainActor.run {
                guard let self,
                      let current = self.sharingState.drafts.firstIndex(where: { $0.id == id }) else { return }
                self.sharingState.drafts[current].isAnalyzingPauses = false
                self.sharingState.drafts[current].acousticPauseDecisions = result.0
                if let failure = result.1 {
                    self.sharingState.drafts[current].preparationMessage =
                        "Pause analysis was unavailable (\(failure)). Filler and manual text edits remain reviewable."
                }
                self.applyShareEditState(at: current)
            }
        }
    }

    private func renderCleanup(forShareDraft id: String) {
        guard let index = sharingState.drafts.firstIndex(where: { $0.id == id }),
              let sourcePath = sharingState.drafts[index].interjection.audioPath,
              let sourceURL = resolvedInterjectionAudioURL(for: sourcePath),
              let decisions = sharingState.drafts[index].cleanup?.decisions,
              let root = try? applicationSupportDirectory()
                .appending(path: "SpokenMargins/ShareRevisions/\(UUID().uuidString)", directoryHint: .isDirectory) else {
            if let index = sharingState.drafts.firstIndex(where: { $0.id == id }) {
                sharingState.drafts[index].warning = [
                    shareAnchorWarning(for: sharingState.drafts[index].interjection),
                    "The cleaned audio preview could not be prepared. You can still share original voice or text."
                ].compactMap { $0 }.joined(separator: " ")
            }
            return
        }
        sharingState.drafts[index].renderGeneration += 1
        let generation = sharingState.drafts[index].renderGeneration
        sharingState.drafts[index].isPreparingCleanup = true
        let destination = root.appending(path: "cleaned-\(safePodcastEvidenceComponent(id)).m4a")
        let renderer = shareMarginAudioCleanupHandler
        Task.detached { [weak self] in
            do {
                let duration = try await renderer(sourceURL, destination, decisions)
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = destination
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = duration
                    self?.sharingState.drafts[current].representationChoice = .cleaned
                    if let interjection = self?.sharingState.drafts[current].interjection {
                        self?.sharingState.drafts[current].warning = self?.shareAnchorWarning(for: interjection)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let current = self?.sharingState.drafts.firstIndex(where: { $0.id == id }),
                          self?.sharingState.drafts[current].renderGeneration == generation else { return }
                    self?.sharingState.drafts[current].isPreparingCleanup = false
                    self?.sharingState.drafts[current].cleanedAudioURL = nil
                    self?.sharingState.drafts[current].cleanedAudioDurationMs = nil
                    self?.sharingState.drafts[current].representationChoice =
                        self?.originalAudioURL(forShareDraft: id) == nil ? .textOnly : .original
                    self?.sharingState.drafts[current].preparationMessage =
                        "Cleaned voice could not be prepared. Original voice or reviewed text remains available."
                    if let interjection = self?.sharingState.drafts[current].interjection {
                        self?.sharingState.drafts[current].warning = [
                            self?.shareAnchorWarning(for: interjection),
                            "Cleaned audio could not be regenerated. Original voice and reviewed text are still available."
                        ].compactMap { $0 }.joined(separator: " ")
                    }
                }
            }
        }
    }

    private func shareAnchorWarning(for interjection: Interjection) -> String? {
        guard selectedItem.isNativeAudio && (interjection.podcastAnchorEvidence ?? []).isEmpty else {
            return nil
        }
        switch interjection.podcastAnchorEvidenceCaptureStatus {
        case .pendingPostResumeSample:
            return "High-reliability evidence is capturing. Continue podcast playback for about 12 seconds before sharing this Margin."
        case .pendingExactLocalCapture:
            return "High-reliability evidence is being prepared from the podcast edition currently playing."
        case .ready:
            return nil
        case .unavailable, nil:
            return "High-reliability anchor evidence was unavailable at capture. Transcript context may still resolve this Margin; a timestamp alone will not be treated as verified."
        }
    }

    static func mapProposalsForMarginExport(_ proposals: [PortableListeningMapProposalArtifact]) -> [PortableListeningMapProposalArtifact] {
        // The app exports reviewed Margins and textual map proposals, not the
        // local/imported Skim audio. Do not reference unselected voice assets.
        proposals.map { proposal in
            PortableListeningMapProposalArtifact(
                id: proposal.id, schemaVersion: proposal.schemaVersion,
                languageCode: proposal.languageCode, createdAt: proposal.createdAt,
                generator: proposal.generator,
                scenes: proposal.scenes.map { scene in
                    PortableListeningMapScene(
                        id: scene.id, order: scene.order, title: scene.title,
                        summaryText: scene.summaryText, summaryAssetId: nil,
                        summaryProvenance: scene.summaryProvenance,
                        eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                        startAnchor: scene.startAnchor, endAnchor: scene.endAnchor
                    )
                }
            )
        }
    }

    func exportSharedInterjections(presentsReadySheet: Bool = true) {
        guard !sharingState.isBulkPreparing else {
            sharingState.errorMessage = "Finish or cancel bulk preparation before sharing."
            return
        }
        let (drafts, omission) = SharedMarginTextRequirement.shareable(sharingState.drafts.filter(\.isIncluded), text: \.approvedTranscript)
        guard !drafts.isEmpty else {
            sharingState.errorMessage = omission ?? "Select at least one Margin with reviewed text."
            return
        }
        sharingState.isExporting = true
        sharingState.errorMessage = nil
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: selectedItem.id)
            let itemIdentity = sharedItemIdentity(for: item, drafts: drafts)
            let itemTransport = reviewedItemTransport(for: item, identity: itemIdentity)
            var machineEvidence: [ReviewedMachineEvidenceAsset] = []
            var selections: [ReviewedInterjectionSelection] = []

            for (index, draft) in drafts.enumerated() {
                let revisionID = "share-revision-\(UUID().uuidString.lowercased())"
                let cleanedPath = draft.representationChoice == .cleaned ? draft.cleanedAudioURL?.path : nil
                let revision = InterjectionShareRevision(
                    id: revisionID,
                    interjectionId: draft.interjection.id,
                    itemId: draft.interjection.itemId,
                    sessionId: draft.interjection.sessionId,
                    createdAt: Date(),
                    approvedTranscript: draft.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                    cleanedAudioPath: cleanedPath,
                    cleanedAudioDurationMs: draft.representationChoice == .cleaned ? draft.cleanedAudioDurationMs : nil,
                    decisions: draft.cleanup?.decisions ?? [],
                    anchorBefore: draft.anchorBefore,
                    anchorAfter: draft.anchorAfter,
                    status: .senderApproved
                )
                try store.saveInterjectionShareRevision(revision)

                let evidence = sharingState.includesAcousticEvidence
                    ? (draft.interjection.podcastAnchorEvidence ?? []).filter { FileManager.default.fileExists(atPath: $0.localPath) }
                    : []
                machineEvidence.append(contentsOf: evidence.map {
                    ReviewedMachineEvidenceAsset(
                        id: $0.id,
                        path: "assets/evidence/\($0.id).shazamsignature",
                        sourceURL: URL(fileURLWithPath: $0.localPath),
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: ($0.provenance ?? .exactLocalPlaybackEdition).rawValue
                    )
                })
                let anchor = portableAnchor(
                    for: draft.interjection,
                    item: item,
                    machineEvidenceAssetIds: evidence.map(\.id)
                )
                let representation: ReviewedRepresentationSelection
                switch draft.representationChoice {
                case .original:
                    guard let url = draft.interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)),
                          let duration = audioDurationMs(at: url) else {
                        throw SessionKitError.persistenceFailed("selected_original_margin_audio_unavailable")
                    }
                    representation = .originalAudio(sourceURL: url, durationMs: duration)
                case .cleaned:
                    guard let url = draft.cleanedAudioURL else {
                        throw SessionKitError.persistenceFailed("selected_cleaned_margin_audio_unavailable")
                    }
                    representation = .cleanedAudio(sourceURL: url)
                case .textOnly:
                    representation = .textOnly
                }
                selections.append(ReviewedInterjectionSelection(
                    packageScopedId: String(format: "margin-%04d", index + 1),
                    revision: revision,
                    anchor: anchor,
                    representation: representation
                ))
            }

            let mapProposals = Self.mapProposalsForMarginExport(try store.loadPortableListeningMapProposals(itemId: item.id))
            let fingerprintSpines = sharingState.includesAcousticEvidence
                ? try store.loadEditionFingerprintSpine(itemId: item.id).map { [$0] } ?? []
                : []
            let phraseSketches = try store.loadTranscriptPhraseSketch(itemId: item.id).map { [$0] } ?? []
            if let spine = fingerprintSpines.first {
                let directory = try episodeMapDirectory(itemId: item.id)
                let existingEvidenceIDs = Set(machineEvidence.map(\.id))
                for landmark in spine.landmarks where !existingEvidenceIDs.contains(landmark.signatureAssetId) {
                    let url = directory.appending(path: "\(landmark.signatureAssetId).shazamsignature")
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    machineEvidence.append(ReviewedMachineEvidenceAsset(
                        id: landmark.signatureAssetId,
                        path: "assets/evidence/\(landmark.signatureAssetId).shazamsignature",
                        sourceURL: url,
                        durationMs: max(1, landmark.sourceMediaEndMs - landmark.sourceMediaStartMs),
                        anchorOffsetMs: 0,
                        provenance: landmark.provenance.rawValue
                    ))
                }
            }

            let packageID = "package-\(UUID().uuidString.lowercased())"
            let prepared = try SpokenMarginsPackageBuilder.prepare(
                packageId: packageID,
                createdAt: Date(),
                item: itemIdentity,
                itemTransportSelection: itemTransport,
                selections: selections,
                mapProposals: mapProposals,
                fingerprintSpines: fingerprintSpines,
                phraseSketches: phraseSketches,
                machineEvidence: machineEvidence,
                senderDisplayLabel: sharingState.senderDisplayLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            let directory = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/SharedPackages", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(safeShareFilename(item.title))-\(packageID.suffix(8)).spokenmargins")
            _ = try SpokenMarginsPackageArchive.write(prepared, to: destination)
            UserDefaults.standard.set(sharingState.senderDisplayLabel, forKey: "sharingSenderDisplayLabel")
            sharedSpokenMarginsPackageURL = destination
            sharingState.isExporting = false
            if presentsReadySheet {
                isSharingInterjectionsPresented = false
                isSharedSpokenMarginsPackagePresented = true
            }
            diagnostics["lastSharedPackage"] = "margins=\(drafts.count);evidence=\(machineEvidence.count);map=\(mapProposals.isEmpty ? "preparing_or_unavailable" : "included")"
            if let omission { reportWarning(omission) }
        } catch {
            sharingState.isExporting = false
            sharingState.errorMessage = error.localizedDescription
            diagnostics["lastSharedPackageFailure"] = String(describing: error)
        }
    }

    private func sharedItemIdentity(
        for item: Item,
        drafts: [ShareInterjectionDraft]
    ) -> SharedItemIdentity {
        SharedItemIdentityBuilder.exportIdentity(
            for: item,
            draftEditionDigests: drafts.map(\.interjection.sourceExactEditionSHA256),
            localAudioDigest: localAudiobookDigest(for: item)
        )
    }

    private func reviewedItemTransport(
        for item: Item,
        identity: SharedItemIdentity
    ) -> ReviewedItemTransportSelection {
        if identity.canonicalURL != nil {
            return .reference
        }
        let text = item.text ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sharingState.isAppAuthoredItem || sharingState.confirmsPrivateSharingRights {
            return .embeddedText(
                text: text,
                originalMediaType: identity.itemType.rawValue,
                rightsBasis: sharingState.isAppAuthoredItem ? .appAuthored : .senderConfirmedPrivateRights
            )
        }
        return .recipientSupplied
    }

    /// Mirrors the link the packet builder keeps, so the share screen never promises a private feed link (#168).
    private func secureSharedItemURL(for item: Item) -> String? {
        ShareableLinkPolicy.shareableLink(
            item.externalReference.flatMap(normalizedSharingURL)
                ?? item.media?.url.flatMap(normalizedSharingURL)
        )
    }

    private func sharedItemType(for item: Item) -> SharedItemType {
        SharedItemIdentityBuilder.itemType(for: item)
    }

    private func portableAnchor(
        for interjection: Interjection,
        item: Item,
        machineEvidenceAssetIds: [String]
    ) -> PortableAnchorEvidence {
        let exactText: String?
        if !selectedItem.isNativeAudio,
           interjection.anchor.endChar > interjection.anchor.startChar,
           interjection.anchor.endChar <= (item.text ?? "").count {
            let text = item.text ?? ""
            let lower = text.index(text.startIndex, offsetBy: interjection.anchor.startChar)
            let upper = text.index(text.startIndex, offsetBy: interjection.anchor.endChar)
            exactText = String(text[lower..<upper])
        } else {
            exactText = nil
        }
        let chapter = selectedItem.mediaChapters.last {
            $0.startMs <= (interjection.anchor.mediaTimeMs ?? -1)
        }?.title
        return PortableAnchorEvidence(
            anchorType: interjection.anchor.anchorType,
            startChar: selectedItem.isNativeAudio ? nil : interjection.anchor.startChar,
            endChar: selectedItem.isNativeAudio ? nil : interjection.anchor.endChar,
            exactText: exactText,
            prefix: interjection.anchor.anchorBefore,
            suffix: interjection.anchor.anchorAfter,
            mediaTimeMs: interjection.anchor.mediaTimeMs,
            roughPercent: interjection.roughPercent,
            transcriptSegmentId: interjection.anchor.transcriptSegmentId,
            chapterTitle: chapter,
            machineEvidenceAssetIds: machineEvidenceAssetIds
        )
    }

    private func audioDurationMs(at url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return max(1, Int((Double(file.length) / file.processingFormat.sampleRate * 1_000).rounded()))
    }

    private func safeShareFilename(_ value: String) -> String {
        let normalized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((normalized.isEmpty ? "Spoken-Margins" : normalized).prefix(80))
    }

    func setImportedCommentaryLayerEnabled(_ layerID: String, enabled: Bool) {
        updateImportedCommentaryLayer(layerID) { $0.isEnabled = enabled }
    }

    func setImportedCommentaryLayerMuted(_ layerID: String, muted: Bool) {
        updateImportedCommentaryLayer(layerID) { $0.isMuted = muted }
    }

    func setImportedCommentaryRevealMode(_ layerID: String, mode: ImportedCommentaryRevealMode) {
        updateImportedCommentaryLayer(layerID) { $0.revealMode = mode }
    }

    var hasEnabledImportedCommentary: Bool {
        selectedItem.importedCommentaryLayers.contains { layer in
            Self.isImportedCommentaryLayerPlaybackEligible(
                layer,
                records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
            )
        }
    }

    var importedCommentaryAutoPlayEnabled: Bool {
        let enabledLayers = selectedItem.importedCommentaryLayers.filter { layer in
            Self.isImportedCommentaryLayerPlaybackEligible(
                layer,
                records: selectedItem.importedCommentaryInterjections[layer.id] ?? []
            )
        }
        return !enabledLayers.isEmpty && enabledLayers.allSatisfy { $0.revealMode == .guided }
    }

    nonisolated static func isImportedCommentaryLayerPlaybackEligible(
        _ layer: ImportedCommentaryLayer,
        records: [ImportedCommentaryInterjection]
    ) -> Bool {
        guard layer.deletedAt == nil,
              layer.isEnabled,
              layer.sourceResolutionStatus != .wrongSource else { return false }
        return records.contains { isPlayableImportedCommentaryResolution($0.resolution) }
    }

    func setImportedCommentaryAutoPlayEnabled(_ enabled: Bool) {
        do {
            let store = try requireStore()
            let layerIDs = selectedItem.importedCommentaryLayers.compactMap { layer in
                layer.deletedAt == nil && layer.isEnabled ? layer.id : nil
            }
            for layerID in layerIDs {
                guard var layer = try store.loadImportedCommentaryLayer(id: layerID) else { continue }
                layer.revealMode = enabled ? .guided : .companion
                try store.saveImportedCommentaryLayer(layer)
            }
            refreshSelectedItem()
            reportConfirmation(enabled
                ? "Shared Margins will play automatically after their cue."
                : "Shared Margins will wait for you to choose Listen or Dismiss.")
        } catch {
            reportFailure(error, context: "Shared Margin auto-play setting could not be saved")
        }
    }

    func deleteImportedCommentaryLayer(_ layerID: String) {
        updateImportedCommentaryLayer(layerID) {
            $0.deletedAt = Date()
            $0.isEnabled = false
        }
    }

    private func updateImportedCommentaryLayer(
        _ layerID: String,
        mutation: (inout ImportedCommentaryLayer) -> Void
    ) {
        do {
            let store = try requireStore()
            guard var layer = try store.loadImportedCommentaryLayer(id: layerID) else { return }
            mutation(&layer)
            try store.saveImportedCommentaryLayer(layer)
            refreshSelectedItem()
        } catch {
            reportFailure(error, context: "Shared Margin settings could not be saved")
        }
    }

    private func persistExportSettings() {
        UserDefaults.standard.set(exportFormat, forKey: "exportFormat")
        UserDefaults.standard.set(exportScope, forKey: "exportScope")
        UserDefaults.standard.set(exportIncludesSourceText, forKey: "exportIncludesSourceText")
        UserDefaults.standard.set(exportIncludesReference, forKey: "exportIncludesReference")
        UserDefaults.standard.set(exportIncludesListeningMap, forKey: "exportIncludesListeningMap")
        UserDefaults.standard.set(exportIncludesInterjections, forKey: "exportIncludesInterjections")
        UserDefaults.standard.set(exportIncludesTurns, forKey: "exportIncludesTurns")
    }

    private func currentExportOptions() -> ExportOptions {
        currentExportOptions(sessionId: exportSessionId)
    }

    private func currentExportOptions(sessionId: String?) -> ExportOptions {
        ExportOptions(
            sessionId: sessionId,
            includeFullText: exportIncludesSourceText,
            includeReference: exportIncludesReference,
            includeListeningMap: exportIncludesListeningMap,
            includeInterjections: exportIncludesInterjections,
            includeTurns: exportIncludesTurns,
            scope: exportScope
        )
    }

    private func renderExport(_ export: SessionExport, format: String? = nil) throws -> String {
        if (format ?? exportFormat) == "json" {
            let data = try encoder.encode(export)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return SessionExportMarkdownRenderer.render(export)
    }

    private func prepareIndividualMarkdownExportFile(markdown: String, export: SessionExport) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsSessionShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let exportFileURL, exportFileURL.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: exportFileURL)
        }
        let session = try store?.loadSession(id: export.session.id)
        return try SessionMarkdownFileWriter().write(
            markdown: markdown,
            itemTitle: export.item.title,
            sessionDate: session?.createdAt ?? session?.updatedAt,
            sessionId: export.session.id,
            to: directory
        )
    }

    private func resolvedBatchExportFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: batchExportFolderBookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: quickAccessBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshed = try url.bookmarkData(
                    options: quickAccessBookmarkCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshed, forKey: batchExportFolderBookmarkKey)
            }
            return url
        } catch {
            diagnostics["batchExportBookmarkError"] = String(describing: error)
            return nil
        }
    }

    private func resolvedQuickAccessFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: quickAccessFolderBookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: quickAccessBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshed = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: quickAccessFolderBookmarkKey)
            }
            return url
        } catch {
            diagnostics["quickAccessBookmarkError"] = String(describing: error)
            return nil
        }
    }

    private var quickAccessBookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private var quickAccessBookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private func obsidianItemId(fileName: String, index: Int) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "item-obsidian-\(Int(Date().timeIntervalSince1970))-\(index)-\(base.isEmpty ? "clip" : base)"
    }

    private func requireLocalSourceImporter() throws -> LocalSourceImporter {
        if let localSourceImporter { return localSourceImporter }
        let store = try requireStore()
        try configureOfflineServices(store: store)
        guard let localSourceImporter else {
            throw SessionKitError.persistenceFailed("local_source_importer_unavailable")
        }
        return localSourceImporter
    }

    func podcastLocalAssetDidBecomeReady(itemId: String, url: URL) {
        guard let engine, let store else { return }
        importedPodcastRecipientLocalURLs[itemId] = url
        let requestedReplacement = requestedPodcastTransportReplacements.remove(itemId) != nil
        run { _ in
            // Automatic completion keeps the current session's audio edition.
            // Explicit Download Again and a pending startup may adopt the new
            // file, including when a paused session's old local file was replaced.
            snapshot = try engine.updatePlaybackTransport(
                itemId: itemId,
                playbackURL: url.absoluteString,
                replaceActivePlayback: snapshot.status == .starting || requestedReplacement
            )
            refreshSelectedItem()
        }
        scheduleEmbeddedPublisherChapterImport(itemId: itemId, localURL: url)
        retrySourceWindowContexts(itemId: itemId)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: url)
        if importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store),
           let item = try? store.loadItem(id: itemId) {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_for_imported_commentary"
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: url)
            return
        }
        guard pendingMapGenerationItemId == itemId,
              (try? store.loadItem(id: itemId)) != nil else {
            diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "not_requested"
            return
        }
        pendingMapGenerationItemId = nil
        diagnostics["sourceTranscriptionAfterDownload:\(itemId)"] = "requested_private_episode_map"
        prepareEpisodeMap(itemId: itemId, policy: .explicit)
    }

    private func scheduleTransientRecipientAlignmentTranscript(for item: Item, localSourceURL: URL) {
        guard importedTranscriptRetryDates[item.id].map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        importedTranscriptRetryDates[item.id] = Date()
        diagnostics["recipientAlignmentTranscript:\(item.id)"] = "transcribing_transiently"
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: localSourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                if self.importedPodcastResolutionURLs[item.id] == localSourceURL {
                    self.resolveImportedPodcastCommentary(
                        itemId: item.id, localURL: localSourceURL, recipientTranscriptOverride: timeline)
                }
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "consumed_and_deleted"
            } catch {
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "failed_and_deleted:\(error.localizedDescription)"
            }
        }
    }

    nonisolated static func invalidatePodcastEdition(itemId: String, digest: String, store: SQLiteSessionStore) throws {
        for var layer in try store.loadImportedCommentaryLayers(itemId: itemId)
        where layer.deletedAt == nil && layer.itemIdentity.itemType == .podcast
            && layer.resolvedRecipientEditionSHA256 != digest {
            layer.sourceResolutionStatus = .pending
            layer.resolvedRecipientEditionSHA256 = nil
            try store.saveImportedCommentaryLayer(layer)
            for var note in try store.loadImportedCommentaryInterjections(layerId: layer.id) {
                note.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
                try store.saveImportedCommentaryInterjection(note)
            }
        }
        if let projection = try store.loadResolvedListeningMapProjection(itemId: itemId),
           projection.recipientEditionSHA256 != digest {
            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: projection.id, itemId: itemId, proposalId: projection.proposalId,
                recipientEditionSHA256: digest, points: [], intervals: []))
        }
    }

    nonisolated static func podcastResolution(
        previous: ImportedAnchorResolution, proposed: ImportedAnchorResolution,
        previousEdition: String?, currentEdition: String?, hasTranscript: Bool
    ) -> ImportedAnchorResolution {
        let sameEdition = currentEdition != nil && currentEdition == previousEdition
        let verified = isInlinePodcastResolution(previous)
            && previous.evidenceClass != .timestampFallback && previous.evidenceClass != .mapInterpolated
        let weaker = proposed.evidenceClass == .unresolved || proposed.evidenceClass == .absentFromRecipientEdition
            || (!hasTranscript && proposed.evidenceClass == .ambiguous
                && (previous.evidenceClass == .transcriptVerified || previous.evidenceClass == .fused))
        return sameEdition && verified && weaker ? previous : proposed
    }

    func resolveImportedPodcastCommentary(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) {
        guard let store,
              let item = try? store.loadItem(id: itemId),
              let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              !layers.isEmpty else { return }
        // Playback refreshes must not cancel a stronger transient-transcript pass.
        guard recipientTranscriptOverride != nil || !transcriptAssistedResolutionItems.contains(itemId)
            || importedPodcastResolutionURLs[itemId] != localURL else { return }
        if importedPodcastResolutionURLs[itemId] != localURL { transcriptAssistedResolutionItems.remove(itemId) }
        importedPodcastResolutionURLs[itemId] = localURL
        let localItem = localSharedItemIdentity(for: item)
        // Persisted transcripts have no byte-edition binding. Only this pass's
        // transient transcript is evidence for the supplied recipient file.
        let recipientTranscript = recipientTranscriptOverride
        let work = layers.compactMap { layer -> (ImportedCommentaryLayer, [ImportedCommentaryInterjection])? in
            guard layer.deletedAt == nil,
                  layer.itemIdentity.itemType == .podcast,
                  let records = try? store.loadImportedCommentaryInterjections(layerId: layer.id),
                  !records.isEmpty else { return nil }
            return (layer, records)
        }
        guard !work.isEmpty else { return }
        if recipientTranscript == nil, importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
        }
        if recipientTranscriptOverride != nil { transcriptAssistedResolutionItems.insert(itemId) }
        let generation = (importedPodcastResolutionGenerations[itemId] ?? 0) + 1
        importedPodcastResolutionGenerations[itemId] = generation
        let applicationSupportDirectory = try? applicationSupportDirectory()
        diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "scheduled:\(work.count)"
        Task.detached { [weak self] in
            do {
                let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                let isCurrent = try await MainActor.run { [weak self] in
                    guard let self, self.importedPodcastResolutionGenerations[itemId] == generation else { return false }
                    try Self.invalidatePodcastEdition(itemId: itemId, digest: recipientDigest, store: store)
                    if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                    return true
                }
                guard isCurrent else { return }
                var resolvedWork: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection], SharedListeningMapPlacement.Outcome?)] = []
                for (var layer, records) in work {
                    let queries = records.map { record in
                        let evidence = (record.podcastAnchorEvidence ?? []).compactMap { asset -> PodcastAcousticEvidenceQuery? in
                            guard let assetURL = Self.resolvedApplicationSupportAssetURL(
                                for: asset.localPath,
                                applicationSupportDirectory: applicationSupportDirectory
                            ), let data = try? Data(contentsOf: assetURL) else { return nil }
                            return PodcastAcousticEvidenceQuery(
                                id: asset.id,
                                signatureData: data,
                                anchorOffsetMs: asset.anchorOffsetMs
                            )
                        }
                        return PodcastPortableAnchorQuery(
                            packageScopedId: record.packageScopedId,
                            senderMediaTimeMs: record.anchorEvidence.mediaTimeMs,
                            evidence: evidence,
                            evidenceWasDeclared: !record.anchorEvidence.machineEvidenceAssetIds.isEmpty
                        )
                    }
                    let resolutions = (try? await PodcastAcousticAnchorResolver.resolve(
                        queries: queries,
                        recipientAudioURL: localURL,
                        senderExactEditionSHA256: layer.itemIdentity.exactEditionSHA256,
                        senderDurationMs: layer.itemIdentity.durationMs,
                        strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(
                            layer.itemIdentity,
                            localItem
                        )
                    )) ?? [:]
                    let monotonicResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
                        queries: queries,
                        resolutions: Dictionary(uniqueKeysWithValues: records.map { record in
                            let transcriptResolution = recipientTranscript.map {
                                PodcastTranscriptAnchorResolver.resolve(
                                    anchor: record.anchorEvidence,
                                    recipientTimeline: $0
                                )
                            } ?? ImportedAnchorResolution(
                                evidenceClass: .unresolved,
                                algorithmVersion: "podcast-transcript-anchor.v1"
                            )
                            let acousticResolution = resolutions[record.packageScopedId]
                                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
                            return (
                                record.packageScopedId,
                                PodcastAnchorFusionResolver.fuse(
                                    transcript: transcriptResolution,
                                    acoustic: acousticResolution
                                )
                            )
                        })
                    )
                    let projectedResolutions = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
                        queries: queries,
                        resolutions: monotonicResolutions
                    )
                    let fusedResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
                        queries: queries,
                        resolutions: projectedResolutions
                    )
                    var updated = records
                    for index in updated.indices {
                        if let resolution = fusedResolutions[updated[index].packageScopedId] {
                            updated[index].resolution = Self.podcastResolution(
                                previous: updated[index].resolution, proposed: resolution,
                                previousEdition: layer.resolvedRecipientEditionSHA256,
                                currentEdition: recipientDigest, hasTranscript: recipientTranscript != nil)
                        }
                    }
                    layer.resolvedRecipientEditionSHA256 = recipientDigest
                    let resolutionValues = updated.map(\.resolution)
                    if resolutionValues.allSatisfy(Self.isInlinePodcastResolution) {
                        layer.sourceResolutionStatus = .resolved
                    } else if resolutionValues.contains(where: { $0.evidenceClass == .ambiguous }) {
                        layer.sourceResolutionStatus = .ambiguous
                    } else if resolutionValues.allSatisfy({ $0.evidenceClass == .absentFromRecipientEdition }) {
                        layer.sourceResolutionStatus = .unavailable
                    } else {
                        layer.sourceResolutionStatus = .contextOnly
                    }
                    var mapOutcome: SharedListeningMapPlacement.Outcome?
                    if layer.listeningMapProposals?.first != nil, layer.editionFingerprintSpines?.first == nil {
                        mapOutcome = .notPlaced(.init(sceneId: nil, sceneLabel: nil, reason: .noEvidence))
                    } else if let spine = layer.editionFingerprintSpines?.first, let proposal = layer.listeningMapProposals?.first {
                        let evidencePaths = layer.episodeMapEvidencePaths ?? [:]
                        mapOutcome = try await SharedListeningMapResolver.resolve(
                            proposal: proposal, spine: spine,
                            signatureData: { id in evidencePaths[id].flatMap {
                                Self.resolvedApplicationSupportAssetURL(for: $0, applicationSupportDirectory: applicationSupportDirectory)
                            }.flatMap { try? Data(contentsOf: $0) } },
                            recipientAudioURL: localURL, recipientEditionSHA256: recipientDigest,
                            itemId: itemId, projectionId: SharedListeningMapPlacement.projectionId(layerId: layer.id),
                            strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(layer.itemIdentity, localItem)
                        )
                    }
                    resolvedWork.append((layer, updated, mapOutcome))
                }
                await MainActor.run {
                    guard let self,
                          self.importedPodcastResolutionGenerations[itemId] == generation,
                          let store = self.store else { return }
                    self.transcriptAssistedResolutionItems.remove(itemId)
                    do {
                        let outcomes = resolvedWork.sorted { $0.0.importedAt < $1.0.importedAt }.compactMap(\.2)
                        let current = try store.loadResolvedListeningMapProjection(itemId: itemId)
                        let activation = SharedListeningMapPlacement.activation(
                            outcomes, listenerHasMap: try Self.listenerHasListeningMap(itemId: itemId, store: store),
                            activeProjectionId: current?.id)
                        for (layer, records, outcome) in resolvedWork {
                            var layer = layer
                            layer.sharedMapRefusalReason = activation.refusal == nil ? nil : outcome?.refusal?.listenerReason
                            try store.saveImportedCommentaryLayer(layer)
                            for record in records { try store.saveImportedCommentaryInterjection(record) }
                        }
                        let sharedProposals = Dictionary(resolvedWork.compactMap { work in
                            work.0.listeningMapProposals?.first.map { (SharedListeningMapPlacement.projectionId(layerId: work.0.id), $0) }
                        }, uniquingKeysWith: { first, _ in first })
                        if activation.refusal != nil, let stale = current, sharedProposals[stale.id] != nil {
                            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                                id: stale.id, itemId: itemId, proposalId: stale.proposalId,
                                recipientEditionSHA256: stale.recipientEditionSHA256, points: [], intervals: []))
                        }
                        if let projection = activation.projection {
                            try store.saveResolvedListeningMapProjection(projection)
                            if let proposal = sharedProposals[projection.id] {
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    for scene in proposal.scenes where
                                        scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                                        _ = try? await self.prepareSummaryBridgeAsset(
                                            itemId: itemId,
                                            proposalId: projection.id,
                                            scene: scene,
                                            store: store
                                        )
                                    }
                                    self.updateSkimAvailability()
                                }
                            }
                        }
                        if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                        let resolvedCount = resolvedWork.filter { $0.0.sourceResolutionStatus == .resolved }.count
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "complete:\(resolvedCount)/\(resolvedWork.count)"
                        if recipientTranscript == nil, self.importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
                            self.scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
                        }
                    } catch {
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "persistence_failed:\(error.localizedDescription)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard self?.importedPodcastResolutionGenerations[itemId] == generation else { return }
                    self?.transcriptAssistedResolutionItems.remove(itemId)
                    self?.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "failed:\(error.localizedDescription)"
                }
            }
        }
    }

    private func importedPodcastCommentaryNeedsTranscript(
        itemId: String,
        store: SQLiteSessionStore
    ) -> Bool {
        guard let layers = try? store.loadImportedCommentaryLayers(itemId: itemId) else { return false }
        return layers.contains { layer in
            guard layer.deletedAt == nil,
                  layer.itemIdentity.itemType == .podcast,
                  let records = try? store.loadImportedCommentaryInterjections(layerId: layer.id) else {
                return false
            }
            return records.contains { record in
                !Self.isInlinePodcastResolution(record.resolution)
                    && PodcastTranscriptAnchorResolver.hasUsableContext(record.anchorEvidence)
            }
        }
    }

    nonisolated static func isInlinePodcastResolution(_ resolution: ImportedAnchorResolution) -> Bool {
        guard resolution.localMediaTimeMs != nil else { return false }
        switch resolution.evidenceClass {
        case .exactEdition, .transcriptVerified, .acousticVerified, .fused,
             .mapInterpolated, .timestampFallback, .recipientConfirmed:
            return true
        case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    private func scheduleEmbeddedPublisherChapterImport(itemId: String, localURL: URL) {
        Task { @MainActor [weak self] in
            guard let collection = await EmbeddedPublisherChapterLoader.load(from: localURL),
                  let self,
                  let engine = self.engine else {
                self?.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "not_found"
                return
            }
            self.run { _ in
                self.snapshot = try engine.attachPublisherChapters(itemId: itemId, collection: collection)
                if self.activeItemId == itemId {
                    self.refreshSelectedItem()
                }
                self.diagnostics["publisherChaptersEmbedded:\(itemId)"] = "imported_\(collection.chapters.count)"
            }
        }
    }

    private func schedulePodcastDownloadIfNeeded(itemId: String) {
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.media?.sourceType == .remoteStream,
              let rawURL = item.media?.url,
              let remoteURL = URL(string: rawURL) else { return }
        podcastDownloadCoordinator?.register(itemId: itemId, remoteURL: remoteURL)
    }
}
