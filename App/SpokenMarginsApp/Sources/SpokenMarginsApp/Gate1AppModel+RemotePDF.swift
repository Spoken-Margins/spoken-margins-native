import Foundation
import SessionKit

/// Web PDFs: a PDF shared from Safari or the share sheet, and a PDF link typed or pasted into Link or Podcast whose
/// address has no .pdf ending, such as arXiv's `/pdf/<id>` (#758). The resolver spots those by their `%PDF-` header.
extension Gate1AppModel {
    /// Imports the PDF a Link-field link serves, without changing Now Playing.
    func importPDFFromLinkField(_ url: URL) async throws -> Bool {
        try await importRemotePDFInBackground(url: url, onboardingSteps: [.addedOwnSource])
        reportConfirmation("Added the PDF to Library without changing Now Playing.")
        return true
    }

    @discardableResult
    func importRemotePDFInBackground(
        url: URL,
        onboardingSteps: Set<OnboardingStep> = [.addedOwnSource, .addedFromSafari]
    ) async throws -> String {
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
        let itemId = try await importBrowserTextInBackgroundOffMain(handoff, structuredDocument: extracted.document)
        await keepOriginalPDF(data, itemId: itemId) // #4338: a PDF imported again replaces its item's copy (#556)
        await savePDFClips(extracted.clips, itemId: itemId)
        diagnostics["lastRemotePDFImport"] = url.absoluteString
        markOnboardingSteps(onboardingSteps)
        return itemId
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    /// A PDF the share sheet saved to the app group (#828 returns the new item for the pending-share message).
    func importLocalSharedPDFInBackground(url: URL) async throws -> String {
        #if canImport(PDFKit)
        let (extracted, sourceSHA256) = try await Task.detached(priority: .userInitiated) {
            // The file is hashed a chunk at a time and read by PDFKit from disk; its bytes are never held (#4338).
            let hash = try? SourceCatalogVerifier.sha256(ofFileAt: url)
            return (try NativePDFDocumentExtractor.extractStructured(fromFile: url, sourceSHA256: hash), hash)
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
        let itemId = try await importBrowserTextInBackgroundOffMain(handoff, structuredDocument: extracted.document)
        await keepOriginalPDF(copying: url, itemId: itemId, expectedSHA256: sourceSHA256) // #4338
        await savePDFClips(extracted.clips, itemId: itemId)
        diagnostics["lastSharedPDFImport"] = url.lastPathComponent
        markOnboardingSteps([.addedOwnSource, .addedFromSafari])
        return itemId
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }

    /// The import a PDF takes: a PDF imported again moves its Margins to the new text in the background (#556).
    @discardableResult
    func importBrowserTextInBackgroundOffMain(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument?) async throws -> String {
        let item = try await browserTextImportEngine().importBrowserTextInBackgroundOffMain(
            Self.sanitizedBrowserTextHandoff(handoff), structuredDocument: structuredDocument
        )
        if let store, let support = try? applicationSupportDirectory() {
            let ledger = requireOfflineLedger(store: store, rootDirectory: support)
            await ledger.removeRetiredPreparedAudio(itemId: item.id)
        }
        if item.mediaType == "pdf" { PreparedSpeechHooks.texts.invalidate(itemId: item.id) }
        try await reloadLibraryRowsOffMain(store: try requireStore()) // the rows are on screen when this returns, as before (#2505)
        return recordBackgroundBrowserTextImport(item, handoff: handoff)
    }

    func finishBackgroundBrowserTextImport(_ item: Item, handoff: BrowserTextHandoff) throws -> String {
        if item.mediaType == "pdf" { PreparedSpeechHooks.texts.invalidate(itemId: item.id) }
        libraryItems = try loadLibraryRows(store: try requireStore())
        return recordBackgroundBrowserTextImport(item, handoff: handoff)
    }

    /// `importBrowserTextInBackground` for a caller that is already in a `Task`: the new item is written as before, and
    /// the whole-Library read that follows runs off the main thread and is awaited, so the rows are on screen when this
    /// returns (what `reportAddedToLibrary` and `openItem` read next). The synchronous version stays for the callers
    /// that cannot await (#2256).
    @discardableResult
    func importBrowserTextInBackgroundReloadingOffMain(
        _ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil, listenerAdded: Bool = true
    ) async throws -> String {
        let item = try browserTextImportEngine().importBrowserTextInBackground(
            Self.sanitizedBrowserTextHandoff(handoff), structuredDocument: structuredDocument, listenerAdded: listenerAdded)
        return try await finishBackgroundBrowserTextImportOffMain(item, handoff: handoff)
    }

    func finishBackgroundBrowserTextImportOffMain(_ item: Item, handoff: BrowserTextHandoff) async throws -> String {
        if item.mediaType == "pdf" { PreparedSpeechHooks.texts.invalidate(itemId: item.id) }
        try await reloadLibraryRowsOffMain(store: try requireStore())
        return recordBackgroundBrowserTextImport(item, handoff: handoff)
    }

    private func recordBackgroundBrowserTextImport(_ item: Item, handoff: BrowserTextHandoff) -> String {
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
        diagnostics["lastBackgroundBrowserTextImport"] = item.id
        if let structure = item.documentStructure {
            recordPDFExtractionDiagnostics(structure)
        }
        markOnboardingSteps(onboardingSteps(for: handoff))
        return item.id
    }


    func recordPDFExtractionDiagnostics(_ structure: PDFDocumentStructure) {
        diagnostics["lastPDFExtractionEngine"] = structure.extractionEngine.rawValue
        diagnostics["lastPDFAnalysisStatus"] = structure.analysisStatus.rawValue
        diagnostics["lastPDFPageCount"] = "\(structure.pageCount)"
        diagnostics["lastPDFAnalyzedPageCount"] = "\(structure.analyzedPageCount)"
        diagnostics["lastPDFTableCount"] = "\(structure.tables.count)"
    }

    func onboardingSteps(for handoff: BrowserTextHandoff) -> Set<OnboardingStep> {
        switch handoff.captureMode {
        case .markdownFile, .plainTextFile:
            return [.addedOwnSource, .addedFromFiles]
        case .selectedText, .readablePage:
            return [.addedOwnSource, .addedFromSafari]
        }
    }
}
