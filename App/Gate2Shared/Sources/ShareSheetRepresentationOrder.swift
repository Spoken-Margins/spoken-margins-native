import Foundation

/// Orders the representations a share sheet offers so the share extension
/// tries the cheapest reliable handoff first and the rest as fallbacks.
///
/// When a share includes PDF data, the PDF itself comes before any web URL.
/// Safari has the document it is showing, while a fresh download of the same
/// link can return something else: PubMed Central answers a plain request with
/// an HTML "Preparing to download" page (#271). Copying the PDF file into the
/// App Group does not parse it, so this stays safe for large documents in the
/// memory-limited extension. The URL is only the fallback.
public enum ShareSheetRepresentationOrder {
    public static let pdfIdentifier = "com.adobe.pdf"
    public static let fileURLIdentifier = "public.file-url"
    public static let urlIdentifier = "public.url"
    public static let propertyListIdentifier = "com.apple.property-list"

    public struct Candidate<Provider> {
        public let provider: Provider
        public let identifier: String
    }

    /// The identifiers to try, in order, for one provider.
    public static func preferredIdentifiers(presentsPDF: Bool) -> [String] {
        presentsPDF
            ? [
                SpokenMarginsPackageHandoffStore.uniformTypeIdentifier,
                pdfIdentifier,
                fileURLIdentifier,
                urlIdentifier,
                propertyListIdentifier
            ]
            : [
                SpokenMarginsPackageHandoffStore.uniformTypeIdentifier,
                propertyListIdentifier,
                fileURLIdentifier,
                urlIdentifier
            ]
    }

    /// Every candidate across all providers, best first.
    ///
    /// Safari can put the page URL and the PDF on separate attachments, so a
    /// provider carrying a PDF is tried before one carrying only a link. A
    /// Spoken Margins package still comes first.
    ///
    /// - Parameters:
    ///   - conforms: whether the provider has an item conforming to an identifier.
    ///   - additionalIdentifiers: the provider's other registered identifiers to
    ///     try after the preferred ones, given the preferred list.
    public static func candidates<Provider>(
        from providers: [Provider],
        conforms: (Provider, String) -> Bool,
        additionalIdentifiers: (Provider, [String]) -> [String]
    ) -> [Candidate<Provider>] {
        let ranked = providers.enumerated().map { offset, provider in
            let presentsPDF = conforms(provider, pdfIdentifier)
            let preferred = preferredIdentifiers(presentsPDF: presentsPDF)
            let identifiers = preferred.filter { conforms(provider, $0) }
                + additionalIdentifiers(provider, preferred)
            let rank: Int
            if conforms(provider, SpokenMarginsPackageHandoffStore.uniformTypeIdentifier) {
                rank = 0
            } else if presentsPDF {
                rank = 1
            } else {
                rank = 2
            }
            return (rank: rank, offset: offset, candidates: identifiers.map {
                Candidate(provider: provider, identifier: $0)
            })
        }
        return ranked
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .flatMap(\.candidates)
    }
}
