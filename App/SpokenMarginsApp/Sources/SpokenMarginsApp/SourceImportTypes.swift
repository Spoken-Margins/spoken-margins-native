import Foundation
import SessionKit
import SessionKitPersistence

struct SourceLinkCandidateReviewState: Identifiable, Equatable {
    let request: LinkResolutionRequest
    let result: LinkResolutionResult
    let startSession: Bool

    var id: String { request.id }
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

enum SourceFileImportError: LocalizedError {
    case pdfHasNoExtractableText
    case pdfImportUnavailable
    case remotePDFInvalidResponse
    case remotePDFTooLarge

    var errorDescription: String? {
        switch self {
        case .pdfHasNoExtractableText:
            return "This PDF is only pictures of pages, so there is no text to read aloud. Try a PDF you can select text in."
        case .pdfImportUnavailable:
            return "PDF text extraction is unavailable in this build."
        case .remotePDFInvalidResponse:
            return "The shared link did not return a readable PDF."
        case .remotePDFTooLarge:
            return "This PDF is larger than the 50 MB import limit."
        }
    }
}

struct ObsidianImportBatch: Sendable {
    let prepared: [PreparedObsidianImport]
    let failures: [String]
    /// The same failures with the raw error text, for diagnostics only (#1965).
    var rawFailures: [String] = []
    /// Each imported PDF's or Word document's staged copy by item id: a file address and a hash, never the bytes (#4338,
    /// #4594). It becomes the item's original once the item is saved, and is removed if it does not.
    var staged: [String: PDFOriginalStore.Staged] = [:]
    /// Why a file's copy could not be staged; the import itself goes on without an original.
    var stagingFailures: [String] = []
}
