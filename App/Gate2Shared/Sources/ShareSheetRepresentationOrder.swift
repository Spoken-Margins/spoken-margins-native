import Foundation

/// Orders the representations a share sheet offers so the share extension
/// tries the cheapest reliable handoff first and the rest as fallbacks.
///
/// When a share includes PDF data, the PDF itself comes before any web URL.
/// Safari has the document it is showing, while a fresh download of the same
/// link can return something else: PubMed Central answers a plain request with
/// an HTML "Preparing to download" page (#271). Copying the PDF file into the
/// App Group does not parse it, so this stays safe for large documents in the
/// memory-limited extension. A web link is only ever the fallback: every
/// link representation comes after every other representation, across all
/// attachments, and a link found inside another representation waits too
/// (see `ShareSheetLinkFallback`).
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
                propertyListIdentifier,
                urlIdentifier
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
    /// Safari can put the page URL and the PDF, or the page results carrying
    /// the PDF's bytes, on separate attachments. So a provider carrying a PDF
    /// is tried before the others, and every `public.url` candidate comes
    /// last, after all other providers' files, PDFs and page results. A
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
        let ordered = ranked
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .flatMap(\.candidates)
        return ordered.filter { !isLink($0.identifier) } + ordered.filter { isLink($0.identifier) }
    }

    /// Whether the identifier only ever yields a web link.
    public static func isLink(_ identifier: String) -> Bool {
        identifier == urlIdentifier
    }

    /// Whether a representation after `index` could still yield something other than a link.
    public static func nonLinkRemains(after index: Int, in identifiers: [String]) -> Bool {
        identifiers.indices.contains { $0 > index && !isLink(identifiers[$0]) }
    }
}

/// Holds back a web link found while other representations are still untried.
///
/// A link sends the app to download the document again, which is exactly what
/// fails for PubMed Central (#271). So when a candidate yields a link, whether
/// from `public.url` or from page results without the PDF's bytes, the first
/// such link is kept and the remaining non-link candidates are tried. Any file,
/// PDF or page text they yield wins. The kept link is used only once nothing
/// else is left.
public struct ShareSheetLinkFallback<Import> {
    /// The best-ranked link found so far, used if nothing better turns up.
    public private(set) var deferredLink: Import?

    public init() {}

    /// What to hand off for an import found at `index` in `identifiers`, or nil to keep trying
    /// the next candidate.
    public mutating func accept(_ found: Import, isLink: Bool, at index: Int, in identifiers: [String]) -> Import? {
        guard isLink else { return found }
        if ShareSheetRepresentationOrder.nonLinkRemains(after: index, in: identifiers) {
            if deferredLink == nil { deferredLink = found }
            return nil
        }
        return deferredLink ?? found
    }
}
