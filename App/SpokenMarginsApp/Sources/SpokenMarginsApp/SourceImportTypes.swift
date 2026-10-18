import Foundation
import SessionKit

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
