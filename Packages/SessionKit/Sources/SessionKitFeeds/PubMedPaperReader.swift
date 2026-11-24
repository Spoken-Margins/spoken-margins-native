import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SessionKit

// #5201: a PubMed saved search's RSS (the link its Create RSS button makes) read as papers. The shape is PubMed's own
// "PubMed RSS feeds" reply, recorded under Contracts/fixtures/feeds/pubmed-rss: per item a title, `pubDate`, one
// `dc:creator` per author ("Given Family"), `dc:source` (the journal), `dc:identifier` lines (`pmid:`, `doi:`,
// `pmc:`) and `content:encoded`, whose first paragraph is the citation and whose paragraphs after ABSTRACT are the
// abstract. `description` is a cut-down abstract ending "..." and is never used.

/// What one read of a PubMed RSS gave.
public struct PubMedPaperPage: Equatable, Sendable {
    /// The search's name as the listener gave it on Create RSS (the channel title).
    public var title: String?
    public var entries: [PaperEntry]
    /// Items with no title or no PubMed id.
    public var skippedCount: Int
}

public enum PubMedPaperReaderError: Error, Equatable {
    case responseTooLarge
    /// Not an RSS reply (an HTML error page, a challenge page, JSON).
    case notPubMedRSS
}

public enum PubMedPaperReader {
    /// A Create RSS link asks for 100 items at most; a reply of a few hundred kilobytes is plenty.
    public static let maximumBytes = 8 * 1_024 * 1_024

    public static func read(_ data: Data) throws -> PubMedPaperPage {
        guard data.count <= maximumBytes else { throw PubMedPaperReaderError.responseTooLarge }
        let delegate = RSSDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        // A reply cut off at the item or depth cap still gives the items read before it.
        _ = parser.parse()
        guard delegate.sawRSS, delegate.sawChannel else {
            throw PubMedPaperReaderError.notPubMedRSS
        }
        var entries: [PaperEntry] = []
        var skipped = 0
        var seen = Set<String>()
        for raw in delegate.items {
            guard let entry = entry(from: raw), seen.insert(entry.id).inserted else { skipped += 1; continue }
            entries.append(entry)
        }
        return PubMedPaperPage(title: clean(delegate.channelTitle), entries: entries, skippedCount: skipped)
    }

    // MARK: One item

    static func entry(from raw: RawItem) -> PaperEntry? {
        guard let title = clean(raw.title) else { return nil }
        var pmid: String?
        var doi: String?
        var pmcid: String?
        for identifier in raw.identifiers {
            let text = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let scheme = text[..<colon].lowercased()
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch scheme {
            case "pmid": if pmid == nil, isDigits(value) { pmid = value }
            case "doi": if doi == nil { doi = ZoteroPaperReader.normalizedDOI(value) }
            case "pmc": if pmcid == nil { pmcid = normalizedPMCID(value) }
            default: break
            }
        }
        if pmid == nil, let guid = raw.guid, guid.lowercased().hasPrefix("pubmed:") {
            let value = String(guid.dropFirst("pubmed:".count))
            if isDigits(value) { pmid = value }
        }
        guard let pmid else { return nil }
        let content = raw.content ?? ""
        let paragraphs = paragraphs(of: content)
        return PaperEntry(
            id: "pubmed:\(pmid)",
            provider: .pubmed,
            title: title,
            authors: raw.creators.compactMap(familyName),
            journal: clean(raw.source),
            year: year(citation: paragraphs.first, date: raw.date),
            doi: doi,
            pmid: pmid,
            abstract: abstract(paragraphs),
            pdfURL: pmcid.flatMap(openAccessPDF),
            pageURL: doi.flatMap(ZoteroPaperReader.doiAddress) ?? pubMedPage(pmid),
            dateJoined: raw.pubDate.flatMap(rfc822) ?? raw.date.flatMap(dayDate)
        )
    }

    /// The paper's PubMed page, with none of the feed's tracking parameters.
    static func pubMedPage(_ pmid: String) -> URL? {
        URL(string: "https://\(PaperFeedLink.pubMedHost)/\(pmid)/")
    }

    /// PubMed Central's open-access PDF for `PMC<digits>`, from the PMC Open Access dataset NCBI publishes. A paper
    /// outside the open-access set answers 403 or 404 there, so Add falls to the abstract, as for any PDF link that
    /// fails. (The PDF link on pmc.ncbi.nlm.nih.gov itself answers a challenge page to an app, 2026-11-24.)
    static func openAccessPDF(_ pmcid: String) -> URL? {
        URL(string: "https://pmc-oa-opendata.s3.amazonaws.com/\(pmcid).1/\(pmcid).1.pdf")
    }

    static func normalizedPMCID(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard text.hasPrefix("PMC"), isDigits(String(text.dropFirst(3))) else { return nil }
        return text
    }

    // MARK: Fields

    /// Words that start a family name when they stand before its last word ("Van den Kerkhof", "da Silva").
    private static let particles: Set<String> = [
        "van", "von", "der", "den", "de", "del", "della", "di", "da", "dos", "das", "du", "la", "le", "ter", "ten",
        "el", "al", "bin", "ibn", "st", "st.",
    ]

    /// "Magali Van den Kerkhof" → "Van den Kerkhof", "Anil K Challa" → "Challa". PubMed writes each author given
    /// names first; a one-word name (a group author's acronym) stands as written.
    static func familyName(_ raw: String) -> String? {
        guard let name = clean(raw) else { return nil }
        let words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return name }
        var start = words.count - 1
        while start > 1, particles.contains(words[start - 1].lowercased()) { start -= 1 }
        return words[start...].joined(separator: " ")
    }

    /// The year in the citation line ("Genome Biol. 2026 Aug 28;27(1):369. doi: …"), else the item's date's year.
    static func year(citation: String?, date: String?) -> Int? {
        if let citation, let match = citation.range(of: #"(?<![0-9])(1[89]|20)[0-9]{2}(?![0-9])"#, options: .regularExpression) {
            return Int(citation[match])
        }
        guard let date, date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
        return year
    }

    /// The abstract: the paragraphs after the bold ABSTRACT heading, up to the PMID line. Nil for NO ABSTRACT.
    static func abstract(_ paragraphs: [String]) -> String? {
        guard let heading = paragraphs.firstIndex(where: { $0.uppercased() == "ABSTRACT" }) else { return nil }
        let body = paragraphs[(heading + 1)...].prefix { !$0.hasPrefix("PMID:") }
        let text = body.joined(separator: "\n\n")
        return text.contains(where: { !$0.isWhitespace }) ? text : nil
    }

    /// `content:encoded`'s `<p>` paragraphs as plain text, tags stripped and references decoded.
    static func paragraphs(of html: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"<p\b[^>]*>([\s\S]*?)</p\s*>"#, options: [.caseInsensitive])
        let source = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let text = FeedArticleBodyText.html(source.substring(with: match.range(at: 1)))
                .replacingOccurrences(of: "\n\n", with: " ")
            return text.isEmpty ? nil : text
        }
    }

    private static func rfc822(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func dayDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 12 && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: The XML

    struct RawItem {
        var title: String?
        var guid: String?
        var pubDate: String?
        var date: String?
        var source: String?
        var content: String?
        var creators: [String] = []
        var identifiers: [String] = []
    }

    private static let dublinCore = "http://purl.org/dc/elements/1.1/"
    private static let contentModule = "http://purl.org/rss/1.0/modules/content/"

    private final class RSSDelegate: NSObject, XMLParserDelegate {
        var sawRSS = false
        var sawChannel = false
        var channelTitle: String?
        var items: [RawItem] = []
        private var current: RawItem?
        private var path: [String] = []
        private var text = ""
        static let maximumItems = 500
        static let maximumDepth = 32

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = key(elementName, namespaceURI)
            path.append(name)
            if path.count > Self.maximumDepth { parser.abortParsing(); return }
            text = ""
            switch (path.count, name) {
            case (1, "rss"): sawRSS = true
            case (2, "channel") where path.first == "rss": sawChannel = true
            case (3, "item") where path.dropLast().elementsEqual(["rss", "channel"]):
                if items.count >= Self.maximumItems { parser.abortParsing(); return }
                current = RawItem()
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = key(elementName, namespaceURI)
            defer { path.removeLast(); text = "" }
            if path.count == 3, name == "title", path.dropLast().elementsEqual(["rss", "channel"]) {
                channelTitle = text
                return
            }
            if path.count == 3, name == "item", let item = current {
                items.append(item)
                current = nil
                return
            }
            guard path.count == 4, current != nil else { return }
            switch name {
            case "title": current?.title = text
            case "guid": current?.guid = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "pubDate": current?.pubDate = text
            case "dc:date": current?.date = text
            case "dc:source": current?.source = text
            case "dc:creator": current?.creators.append(text)
            case "dc:identifier": current?.identifiers.append(text)
            case "content:encoded": current?.content = text
            default: break
            }
        }

        /// Namespaced elements by a fixed prefix, whatever prefix the reply used.
        private func key(_ name: String, _ namespace: String?) -> String {
            switch namespace {
            case PubMedPaperReader.dublinCore: return "dc:" + name
            case PubMedPaperReader.contentModule: return "content:" + name
            case nil, "": return name
            default: return "{\(namespace!)}" + name
            }
        }
    }
}
