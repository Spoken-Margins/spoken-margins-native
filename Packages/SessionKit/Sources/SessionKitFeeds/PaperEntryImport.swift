import Foundation
import SessionKit

// #4341: what Add does with one paper from a followed reading list. The rules are here so they run on Linux; fetching
// the PDF and saving the item stay in the app (`PaperSourcesState`).

/// What tapping Add (or the row's button) on a paper does.
public enum PaperEntryImportRoute: Equatable, Sendable {
    /// The paper is already in the Library: the row says In Library and opens this item.
    case inLibrary(itemId: String)
    /// Fetch this PDF through the existing remote PDF import, with the feed's metadata as the citation fallback
    /// (`PaperCitation.merged`).
    case pdf(URL)
    /// Fetch the PDF stored in the listener's own Zotero library, with their key, then import it as `.pdf` does.
    case storedPDF(attachmentKey: String)
    /// Add the abstract as a short text item (`AbstractItemBuilder`).
    case abstract
    /// Nothing to add: the button is Open, which shows the paper's page. Nil only when the record names no address.
    case open(URL?)

    public static func route(for entry: PaperEntry, existingItemId: String?) -> Self {
        if let existingItemId { return .inLibrary(itemId: existingItemId) }
        if let pdfURL = entry.pdfURL { return .pdf(pdfURL) }
        if entry.storedPDFReachable, let key = entry.storedPDFAttachmentKey { return .storedPDF(attachmentKey: key) }
        if hasAbstract(entry) { return .abstract }
        return .open(entry.pageURL)
    }

    /// The PDF link answered with something that isn't a PDF (a paywall or login page) or failed: the abstract when
    /// there is one, otherwise Open. Never a second try at the PDF, and never an empty item.
    public static func afterPDFFailed(for entry: PaperEntry) -> Self {
        hasAbstract(entry) ? .abstract : .open(entry.pageURL)
    }

    /// The same test `AbstractItemBuilder` applies, so `.abstract` always builds an item.
    static func hasAbstract(_ entry: PaperEntry) -> Bool {
        entry.abstract?.contains { !$0.isWhitespace } == true
    }
}

/// The Design's messages for an Add, word for word, so the screen (PR 5) and the tests read the same text.
public enum PaperAddMessage {
    public static func added(title: String) -> String { "Added “\(title)”." }
    public static let pdfNeedsLoginAbstractAdded = "The PDF needs a login, so the abstract was added."
    public static let couldNotGetPDF = "Couldn't get the PDF."
}

/// The citation a PDF added from a paper source keeps. The PDF's own (#206 extractor) wins when it found a DOI;
/// otherwise the feed's metadata fills DOI, authors, year and title, each only where the feed has a value.
public enum PaperCitation {
    public static func merged(extracted: PDFBibliography?, entry: PaperEntry) -> PDFBibliography? {
        if let extracted, ZoteroPaperReader.normalizedDOI(extracted.doi) != nil { return extracted }
        var citation = extracted ?? PDFBibliography()
        if let doi = entry.doi { citation.doi = doi }
        if !entry.authors.isEmpty { citation.authors = entry.authors }
        if let year = entry.year { citation.year = year }
        citation.title = entry.title
        return citation == PDFBibliography() ? nil : citation
    }
}

/// The text item an abstract-only paper becomes: the paper's title, its citation line, then "Abstract" and the
/// abstract. Its source line says "Abstract", so the Library never passes it off as the paper.
public enum AbstractItemBuilder {
    /// Nil when the paper has no abstract: a Link only paper is never added as an empty item.
    public static func item(for entry: PaperEntry, itemId: String, createdAt: Date) -> Item? {
        guard let abstract = entry.abstract?.trimmingCharacters(in: .whitespacesAndNewlines), !abstract.isEmpty else {
            return nil
        }
        let text = citationLine(for: entry) + "\n\nAbstract\n\n" + abstract
        let author = entry.authorLine
        var item = Item(
            id: itemId,
            title: entry.title,
            mediaType: "text",
            text: text,
            externalReference: entry.pageURL?.absoluteString,
            status: "needs_listening_map",
            externalReferenceType: entry.pageURL == nil ? nil : "url",
            author: author.isEmpty ? nil : author,
            sourceTitle: sourceLine(for: entry.provider),
            sourceURL: entry.pageURL?.absoluteString,
            createdAt: createdAt
        )
        item.publishedAt = entry.year.map(String.init)
        return item
    }

    /// "Abstract · PubMed" or "Abstract · Zotero".
    public static func sourceLine(for provider: PaperSource.Provider) -> String {
        switch provider {
        case .pubmed: return "Abstract · PubMed"
        case .zotero: return "Abstract · Zotero"
        }
    }

    /// "<title>. <authors>. <journal>, <year>." Parts the record lacks are left out with their punctuation, and a
    /// title that already ends a sentence ("…?") gets no second stop.
    public static func citationLine(for entry: PaperEntry) -> String {
        let venue = [entry.journal, entry.year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
        let parts = [entry.title, entry.authorLine, venue].filter { !$0.isEmpty }
        return parts.map(sentence).joined(separator: " ")
    }

    private static func sentence(_ part: String) -> String {
        guard let last = part.last else { return part }
        return ".?!…".contains(last) ? part : part + "."
    }
}

/// Whether a paper is already in the Library, built once when a paper source's screen opens (off the main actor) and
/// asked per row. A match is by DOI first, then by address; never by title, which collides across papers.
public struct PaperLibraryIndex: Sendable {
    private var itemIdByDOI: [String: String] = [:]
    private var itemIdByAddress: [String: String] = [:]

    /// Items in Recently Deleted don't count: their paper shows Add, and adding it again goes through the import's
    /// own re-add path. When two items share a DOI or address, the oldest wins, so the answer doesn't depend on order.
    public init(items: [Item]) {
        let live = items.filter { $0.deletedAt == nil }.sorted { lhs, rhs in
            let (l, r) = (lhs.createdAt ?? .distantFuture, rhs.createdAt ?? .distantFuture)
            return l != r ? l < r : lhs.id < rhs.id
        }
        for item in live {
            var dois: [String] = []
            if let doi = ZoteroPaperReader.normalizedDOI(item.documentStructure?.bibliography?.doi) { dois.append(doi) }
            for address in [item.externalReference, item.sourceURL].compactMap({ $0 }) {
                if let doi = Self.doi(inAddress: address) {
                    dois.append(doi)
                } else if let key = Self.addressKey(address) {
                    if itemIdByAddress[key] == nil { itemIdByAddress[key] = item.id }
                }
            }
            for doi in dois where itemIdByDOI[doi] == nil { itemIdByDOI[doi] = item.id }
        }
    }

    public func itemId(for entry: PaperEntry) -> String? {
        let addresses = [entry.pdfURL, entry.pageURL].compactMap { $0?.absoluteString }
        let dois = ([entry.doi] + addresses.map(Self.doi(inAddress:))).compactMap { $0 }
        for doi in dois { if let id = itemIdByDOI[doi] { return id } }
        for address in addresses {
            if let key = Self.addressKey(address), let id = itemIdByAddress[key] { return id }
        }
        return nil
    }

    /// The DOI a `doi.org` address names, normalized as Zotero's DOIs are.
    static func doi(inAddress address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), host == "doi.org" || host == "dx.doi.org" || host == "www.doi.org"
        else { return nil }
        return ZoteroPaperReader.normalizedDOI(String(components.percentEncodedPath.drop(while: { $0 == "/" })))
    }

    /// One web address however it was written: http and https alike, host lower-cased without `www.`, no fragment,
    /// no trailing slash. The path and query are kept as they are, since servers treat their case as meaningful.
    static func addressKey(_ address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        // A default port is the same address written out; any other port is a different server.
        let port = components.port.flatMap { [80, 443].contains($0) ? nil : ":\($0)" } ?? ""
        return host + port + path + query
    }
}
