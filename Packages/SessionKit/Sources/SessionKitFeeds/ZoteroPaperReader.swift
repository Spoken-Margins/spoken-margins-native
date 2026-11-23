import Foundation
import SessionKit

// #4341: a Zotero library's JSON turned into the papers a followed list shows. It reads bytes the transport already
// fetched; nothing here makes a request or touches the Library.

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
        try read(items: items, attachments: attachments, library: .group(groupID))
    }

    /// The same for either library. A paper of the listener's own library (`.user`) can fetch its stored PDF with their
    /// key, so it reads as PDF; a public group's stored file stays out of reach.
    public static func read(items: Data, attachments: [Data] = [], library: ZoteroPaperAPI.Library) throws -> PaperPage {
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
            guard let entry = entry(from: record, children: children[record.key] ?? [], library: library) else {
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

    private static func entry(from record: Record, children: [Record], library: ZoteroPaperAPI.Library) -> PaperEntry? {
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
        let id: String
        let ownLibrary: Bool
        switch library {
        case .group(let groupID): (id, ownLibrary) = ("zotero:\(groupID):\(record.key)", false)
        case .user(let userID): (id, ownLibrary) = ("zotero:user:\(userID):\(record.key)", true)
        }
        return PaperEntry(
            id: id,
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
            storedPDFReachable: ownLibrary && storedKey != nil,
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

/// One collection of a Zotero library, as "Your collections" lists it.
public struct ZoteroCollection: Equatable, Identifiable, Sendable {
    public var key: String
    public var name: String
    /// The collection it sits in, when it is a subcollection.
    public var parentKey: String?
    /// Zotero's own count of the items in it, when the reply carries one.
    public var itemCount: Int?

    public var id: String { key }

    public init(key: String, name: String, parentKey: String? = nil, itemCount: Int? = nil) {
        self.key = key
        self.name = name
        self.parentKey = parentKey
        self.itemCount = itemCount
    }
}

/// The names a followed list shows, and the collections of a library, read from Zotero's JSON.
public enum ZoteroCollectionReader {
    /// A page of `<library>/collections`, sorted by name as Zotero's own app lists them. Rows without a usable key or
    /// name are left out.
    public static func collections(_ data: Data) throws -> [ZoteroCollection] {
        guard data.count <= ZoteroPaperReader.maximumBytes else { throw ZoteroPaperReaderError.responseTooLarge }
        let rows: [ZoteroPaperReader.Lossy<CollectionRecord>]
        do { rows = try JSONDecoder().decode([ZoteroPaperReader.Lossy<CollectionRecord>].self, from: data) } catch {
            throw ZoteroPaperReaderError.notZoteroJSON
        }
        let collections = rows.compactMap(\.value).compactMap { record -> ZoteroCollection? in
            guard let name = record.data.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  record.key.count == 8
            else { return nil }
            return ZoteroCollection(key: record.key, name: name, parentKey: record.data.parentCollection, itemCount: record.meta?.numItems)
        }
        return collections.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.key < rhs.key : order == .orderedAscending
        }
    }

    /// The name in a collection's or a group's own record (`data.name`).
    public static func name(_ data: Data) -> String? {
        guard data.count <= ZoteroPaperReader.maximumBytes,
              let record = try? JSONDecoder().decode(NamedRecord.self, from: data),
              let name = record.data.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return nil }
        return name
    }

    /// The library's own name, which every record carries (`library.name`): a group's name, or for the listener's
    /// own library what Zotero calls it.
    public static func libraryName(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([ZoteroPaperReader.Lossy<LibraryHolder>].self, from: data) {
            return rows.compactMap(\.value).compactMap(\.library?.name).first { !$0.isEmpty }
        }
        return (try? decoder.decode(LibraryHolder.self, from: data))?.library?.name
    }

    struct CollectionRecord: Decodable {
        var key: String
        var data: Fields
        var meta: Meta?

        struct Fields: Decodable {
            var name: String?
            /// `false` at the top level, a key in a subcollection.
            var parentCollection: String?

            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: Key.self)
                name = box.text(.name)
                parentCollection = box.text(.parentCollection)
            }

            private enum Key: String, CodingKey { case name, parentCollection }
        }

        struct Meta: Decodable {
            var numItems: Int?
            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: Key.self)
                numItems = try? box.decodeIfPresent(Int.self, forKey: .numItems)
            }
            private enum Key: String, CodingKey { case numItems }
        }
    }

    struct NamedRecord: Decodable {
        var data: CollectionRecord.Fields
    }

    struct LibraryHolder: Decodable {
        var library: Library?
        struct Library: Decodable {
            var name: String?
            init(from decoder: Decoder) throws {
                let box = try decoder.container(keyedBy: Key.self)
                name = box.text(.name)
            }
            private enum Key: String, CodingKey { case name }
        }
    }
}

private extension KeyedDecodingContainer {
    func text(_ key: Key) -> String? { (try? decodeIfPresent(String.self, forKey: key)) ?? nil }
}
