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
        let itemId = try importBrowserTextInBackground(handoff, structuredDocument: extracted.document)
        diagnostics["lastRemotePDFImport"] = url.absoluteString
        markOnboardingSteps(onboardingSteps)
        return itemId
        #else
        throw SourceFileImportError.pdfImportUnavailable
        #endif
    }
}
