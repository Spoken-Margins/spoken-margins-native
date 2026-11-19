import Foundation

// #4341 PR 2 (hidden): a Zotero library's JSON turned into the papers a followed list shows. It reads bytes the
// transport already fetched; nothing here makes a request or touches the Library.

/// What the listener can do with a paper: the Design's three statuses.
public enum PaperEntryStatus: String, Equatable, Sendable {
    /// A PDF the phone can fetch without a key.
    case pdf
    /// No PDF, but the record carries an abstract the app can read aloud.
    case abstractOnly
    /// Neither: the button is Open, which shows the paper's page.
    case linkOnly
}

public struct PaperEntry: Equatable, Identifiable, Sendable {
    public var id: String
    public var provider: PaperSource.Provider
    public var title: String
    /// Family names (or the one-field name of a group author), authors first. Editors only when there is no author.
    public var authors: [String]
    public var journal: String?
    public var year: Int?
    /// Lower-case, without a `doi:` or `https://doi.org/` prefix, so two spellings of one DOI match.
    public var doi: String?
    public var pmid: String?
    public var abstract: String?
    /// A PDF reachable without a key: a linked file whose address is a PDF.
    public var pdfURL: URL?
    /// A PDF stored in Zotero's file storage (needs the listener's key, PR 6). Never fetched from a public library.
    public var storedPDFAttachmentKey: String?
    /// Where Open goes: the DOI's address, else the record's own address, else its Zotero page.
    public var pageURL: URL?
    /// When the paper joined the list (Zotero's `dateAdded`), never its publication year.
    public var dateJoined: Date?

    public var status: PaperEntryStatus {
        if pdfURL != nil { return .pdf }
        if abstract != nil { return .abstractOnly }
        return .linkOnly
    }

    /// "Smith, Jones et al." as the paper row prints it: two names, then "et al." for more.
    public var authorLine: String {
        switch authors.count {
        case 0: return ""
        case 1, 2: return authors.joined(separator: ", ")
        default: return authors.prefix(2).joined(separator: ", ") + " et al."
        }
    }
}

public struct PaperPage: Equatable, Sendable {
    public var entries: [PaperEntry]
    /// Rows that were not papers (notes, standalone attachments, annotations) or had no title.
    public var skippedCount: Int
}

public enum ZoteroPaperReaderError: Error, Equatable, Sendable {
    case responseTooLarge
    /// The bytes weren't a Zotero item list.
    case notZoteroJSON
}

public enum ZoteroPaperReader {
    public static let maximumBytes = 16 * 1_024 * 1_024
    /// A followed list keeps this many of the newest papers (the Design's storage rule).
    public static let maximumEntries = 500

    /// Reads one page of `items/top` and, when given, the list's attachments (any number of pages, each passed in
    /// turn). Papers come back newest-joined first.
    public static func read(items: Data, attachments: [Data] = [], groupID: Int) throws -> PaperPage {
        guard items.count <= maximumBytes, attachments.allSatisfy({ $0.count <= maximumBytes }) else {
            throw ZoteroPaperReaderError.responseTooLarge
        }
        let decoder = JSONDecoder()
        let rows: [Lossy<Record>]
        do { rows = try decoder.decode([Lossy<Record>].self, from: items) } catch { throw ZoteroPaperReaderError.notZoteroJSON }
        let records = rows.compactMap(\.value)
        var children: [String: [Record]] = [:]
        for page in attachments {
            // Attachments only decide a paper's status. A page that fails (an error body, a cut-off reply) leaves
            // those papers as abstract-only or link-only and never costs the list.
            guard let rows = try? decoder.decode([Lossy<Record>].self, from: page) else { continue }
            for row in rows.compactMap(\.value) {
                guard let parent = row.data.parentItem else { continue }
                children[parent, default: []].append(row)
            }
        }
        var entries: [PaperEntry] = []
        var skipped = rows.count - records.count
        for record in records {
            guard let entry = entry(from: record, children: children[record.key] ?? [], groupID: groupID) else {
                skipped += 1
                continue
            }
            entries.append(entry)
        }
        // Stable: papers added in the same second keep the library's own order.
        let ordered = entries.enumerated().sorted { lhs, rhs in
            let left = lhs.element.dateJoined ?? .distantPast
            let right = rhs.element.dateJoined ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        return PaperPage(entries: Array(ordered.prefix(maximumEntries)), skippedCount: skipped)
    }

    private static let notPapers: Set<String> = ["note", "attachment", "annotation"]

    private static func entry(from record: Record, children: [Record], groupID: Int) -> PaperEntry? {
        let data = record.data
        guard !notPapers.contains(data.itemType) else { return nil }
        let title = clean(data.title) ?? clean(data.shortTitle)
        guard let title else { return nil }
        let doi = normalizedDOI(data.DOI)
        let abstract = clean(data.abstractNote)
        var pdfURL: URL?
        var storedKey: String?
        for child in children where isPDF(child.data) {
            switch child.data.linkMode {
            case "linked_url":
                if pdfURL == nil, let url = webURL(child.data.url) { pdfURL = url }
            case "imported_file", "imported_url":
                // The file sits in Zotero's storage, which a public library doesn't open without a key.
                if storedKey == nil { storedKey = child.key }
            default:
                break
            }
        }
        return PaperEntry(
            id: "zotero:\(groupID):\(record.key)",
            provider: .zotero,
            title: title,
            authors: authors(data.creators ?? []),
            journal: [data.publicationTitle, data.bookTitle, data.proceedingsTitle, data.encyclopediaTitle]
                .lazy.compactMap(clean).first,
            year: year(parsedDate: record.meta?.parsedDate, date: data.date),
            doi: doi,
            pmid: clean(data.PMID) ?? pmid(fromExtra: data.extra),
            abstract: abstract,
            pdfURL: pdfURL,
            storedPDFAttachmentKey: storedKey,
            pageURL: doi.flatMap(doiAddress)
                ?? webURL(data.url)
                ?? webURL(record.links?.alternate?.href),
            dateJoined: data.dateAdded.flatMap(date(from:))
        )
    }

    // MARK: Fields

    static func isPDF(_ attachment: Item) -> Bool {
        guard attachment.itemType == "attachment", let type = attachment.contentType else { return false }
        return type.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/pdf"
    }

    private static func authors(_ creators: [Creator]) -> [String] {
        func name(_ creator: Creator) -> String? { clean(creator.lastName) ?? clean(creator.name) }
        let authors = creators.filter { $0.creatorType == "author" }.compactMap(name)
        if !authors.isEmpty { return authors }
        let nonEditors = creators.filter { $0.creatorType != "editor" }.compactMap(name)
        return nonEditors.isEmpty ? creators.compactMap(name) : nonEditors
    }

    /// `parsedDate` is Zotero's own reading of the free-text `date` ("2021-03", "1974", "Spring 1999").
    static func year(parsedDate: String?, date: String?) -> Int? {
        for text in [parsedDate, date] {
            guard let text else { continue }
            let digits = Array(text.utf8)
            var index = 0
            while index + 4 <= digits.count {
                let window = digits[index..<index + 4]
                let before = index > 0 ? digits[index - 1] : 0
                let after = index + 4 < digits.count ? digits[index + 4] : 0
                if window.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), !isDigit(before), !isDigit(after),
                   let year = Int(String(decoding: window, as: UTF8.self)), (1000...2999).contains(year) {
                    return year
                }
                index += 1
            }
        }
        return nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// Lower-cased DOI with any `doi:`, `https://doi.org/` or `https://dx.doi.org/` prefix and spaces removed; nil
    /// unless what's left starts `10.`.
    public static func normalizedDOI(_ raw: String?) -> String? {
        guard var text = clean(raw)?.lowercased() else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"] {
            if text.hasPrefix(prefix) { text.removeFirst(prefix.count); break }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        text = text.removingPercentEncoding ?? text
        guard text.hasPrefix("10."), text.contains("/"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// The DOI's address, with characters that would end the path (`#`, `?`, `%`) escaped so they stay in the DOI.
    static func doiAddress(_ doi: String) -> URL? {
        doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "https://doi.org/\($0)") }
    }

    private static func pmid(fromExtra extra: String?) -> String? {
        guard let extra else { return nil }
        for line in extra.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "pmid" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) { return value }
        }
        return nil
    }

    private static func webURL(_ text: String?) -> URL? {
        guard let text = clean(text), let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: The JSON, as little of it as is read

    /// One row that doesn't read is dropped; the rest of the page stands.
    struct Lossy<Wrapped: Decodable>: Decodable {
        var value: Wrapped?
        init(from decoder: Decoder) throws { value = try? Wrapped(from: decoder) }
    }

    struct Record: Decodable {
        var key: String
        var data: Item
        var meta: Meta?
        var links: Links?
    }

    struct Meta: Decodable { var parsedDate: String? }
    struct Links: Decodable {
        var alternate: Link?
        struct Link: Decodable { var href: String? }
    }

    struct Creator: Decodable {
        var creatorType: String?
        var firstName: String?
        var lastName: String?
        var name: String?

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: Key.self)
            creatorType = box.text(.creatorType)
            firstName = box.text(.firstName)
            lastName = box.text(.lastName)
            name = box.text(.name)
        }

        private enum Key: String, CodingKey { case creatorType, firstName, lastName, name }
    }

    /// Zotero writes `false` for some empty fields (`parentCollection`), so every text field is read on its own and
    /// a field of any other type reads as absent instead of failing the page.
    struct Item: Decodable {
        var itemType: String
        var title: String?
        var shortTitle: String?
        var creators: [Creator]?
        var abstractNote: String?
        var publicationTitle: String?
        var bookTitle: String?
        var proceedingsTitle: String?
        var encyclopediaTitle: String?
        var date: String?
        var DOI: String?
        var PMID: String?
        var extra: String?
        var url: String?
        var dateAdded: String?
        var parentItem: String?
        var linkMode: String?
        var contentType: String?

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: Key.self)
            itemType = try box.decode(String.self, forKey: .itemType)
            title = box.text(.title)
            shortTitle = box.text(.shortTitle)
            creators = try? box.decodeIfPresent([Creator].self, forKey: .creators)
            abstractNote = box.text(.abstractNote)
            publicationTitle = box.text(.publicationTitle)
            bookTitle = box.text(.bookTitle)
            proceedingsTitle = box.text(.proceedingsTitle)
            encyclopediaTitle = box.text(.encyclopediaTitle)
            date = box.text(.date)
            DOI = box.text(.DOI)
            PMID = box.text(.PMID)
            extra = box.text(.extra)
            url = box.text(.url)
            dateAdded = box.text(.dateAdded)
            parentItem = box.text(.parentItem)
            linkMode = box.text(.linkMode)
            contentType = box.text(.contentType)
        }

        private enum Key: String, CodingKey {
            case itemType, title, shortTitle, creators, abstractNote, publicationTitle, bookTitle, proceedingsTitle
            case encyclopediaTitle, date, DOI, PMID, extra, url, dateAdded, parentItem, linkMode, contentType
        }
    }
}

private extension KeyedDecodingContainer {
    func text(_ key: Key) -> String? { (try? decodeIfPresent(String.self, forKey: key)) ?? nil }
}
