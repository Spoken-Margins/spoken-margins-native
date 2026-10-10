import Foundation
import SessionKit

/// Turns a shared-Margins import failure into a sentence for the import sheet. Internal codes stay in diagnostics.
enum SharedMarginsImportMessage {
    static func userFacing(_ error: Error) -> String {
        if error is DecodingError {
            // For example a packet from the parked co-op build, which used a Margin type this build doesn't know.
            return unreadablePackageMessage
        }
        if let urlError = error as? URLError {
            return Gate1AppModel.userFacingMessage(for: urlError)
        }
        if case .persistenceFailed(let code) = error as? SessionKitError {
            switch code {
            case "shared_podcast_item_is_ambiguous":
                return "Couldn’t tell which episode these Margins belong to. Add the episode to your Library, then open the Margins again."
            case "shared_podcast_item_has_no_reference":
                return "These Margins don’t say which episode they belong to, so they can’t be placed. Add the episode to your Library, then open them again."
            case "shared_podcast_item_not_created":
                return "Couldn’t add the episode these Margins belong to. Check your connection and try again."
            case "shared_article_unreadable":
                return "Couldn’t read the article these Margins belong to. Open it in Safari and share it to Spoken Margins, then open the Margins again."
            case "shared_item_not_in_library":
                return "These Margins belong to an item that isn’t in your Library. Add it, then open the Margins again."
            case "shared_embedded_item_is_unavailable", "shared_package_repair_item_is_unavailable":
                return "The item these Margins belong to isn’t available. Add it to your Library, then open the Margins again."
            case "shared_package_repair_source_did_not_match":
                return "That source doesn’t match the item these Margins were made on. Add the same item, or cancel the import."
            default:
                return genericMessage
            }
        }
        if case SessionKitError.invalidCommandForState = error { return genericMessage }
        if case SessionKitError.invalidCommandForCapability = error { return genericMessage }
        let description = error.localizedDescription
        // Codes like "rss_episode_ambiguous" are for diagnostics, not people.
        let looksLikeCode = !description.contains(" ") && (description.contains("_") || description.contains(":"))
        return looksLikeCode ? genericMessage : description
    }

    static let unreadablePackageMessage = "These Margins were made by a newer or test version of Spoken Margins, and this version can't read them."

    /// Diagnostics detail for an import failure. A decoding error's own message ("isn't in the correct format")
    /// hides which field failed, so record the coding path and the value's problem instead.
    static func diagnosticDetail(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return "decoding:\(path):\(context.debugDescription.prefix(160))"
        @unknown default:
            return "decoding:\(error.localizedDescription)"
        }
    }

    static let genericMessage = "Couldn’t import these Margins. Try again, or add the item to your Library first."
}
