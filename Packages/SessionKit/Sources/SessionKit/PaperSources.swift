import Foundation

// #4341: a Zotero reading list followed as papers. These are the stored and shown shapes, in SessionKit so the store
// (SessionKitPersistence) can keep a followed list and Following can sort its row among friends and shows. Reading
// Zotero's JSON and recognizing a pasted link are in SessionKitFeeds.

/// A reading list the listener can follow as papers. Its `identifier` is the stable key the stored record uses; two
/// links to the same list give the same value.
public enum PaperSource: Codable, Hashable, Sendable {
    /// A public Zotero group library, or one collection of it (`collectionKey`). Needs no key.
    case zoteroGroup(groupID: Int, collectionKey: String?)
    /// The listener's own Zotero library, or one collection of it, read with the key they connected in Settings.
    case zoteroUser(userID: Int, collectionKey: String?)
    /// A PubMed saved search's RSS link, made with its Create RSS button. `limit` is the item count the link asks
    /// for, when it names a sensible one. Read as papers by `PubMedPaperReader` (#5201).
    case pubMedRSS(token: String, limit: Int?)

    public enum Provider: String, Codable, Sendable { case zotero, pubmed }

    public var provider: Provider {
        switch self {
        case .zoteroGroup, .zoteroUser: return .zotero
        case .pubMedRSS: return .pubmed
        }
    }

    /// Only the listener's own library needs their key; nothing else is ever sent one.
    public var needsZoteroKey: Bool {
        if case .zoteroUser = self { return true }
        return false
    }

    /// The Zotero user whose own library this list reads; nil for a public group or PubMed.
    public var zoteroUserID: Int? {
        if case .zoteroUser(let userID, _) = self { return userID }
        return nil
    }

    /// Whether a connected key belongs to this list: a group or PubMed list needs none, a list of a listener's own
    /// library needs that same user's key (a key connected for another user is never sent for it).
    public func isReadable(connectedUserID: Int?) -> Bool {
        guard let owner = zoteroUserID else { return true }
        return owner == connectedUserID
    }

    public var identifier: String {
        switch self {
        case .zoteroGroup(let groupID, let collectionKey):
            return "zotero:group:\(groupID)" + (collectionKey.map { ":collection:\($0)" } ?? "")
        case .zoteroUser(let userID, let collectionKey):
            return "zotero:user:\(userID)" + (collectionKey.map { ":collection:\($0)" } ?? "")
        case .pubMedRSS(let token, _):
            return "pubmed:rss:\(token)"
        }
    }
}

/// What the listener can do with a paper: the Design's three statuses.
public enum PaperEntryStatus: String, Codable, Equatable, Sendable {
    /// A PDF the phone can fetch: a linked PDF address, or a stored file of a library the listener connected.
    case pdf
    /// No PDF, but the record carries an abstract the app can read aloud.
    case abstractOnly
    /// Neither: the button is Open, which shows the paper's page.
    case linkOnly
}

public struct PaperEntry: Codable, Equatable, Identifiable, Sendable {
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
    /// A PDF stored in Zotero's file storage. Fetched only from the listener's own library, with their key.
    public var storedPDFAttachmentKey: String?
    /// The stored PDF can be fetched: the paper is in the listener's own library, read with their key.
    public var storedPDFReachable: Bool
    /// Where Open goes: the DOI's address, else the record's own address, else its Zotero page.
    public var pageURL: URL?
    /// When the paper joined the list (Zotero's `dateAdded`), never its publication year.
    public var dateJoined: Date?

    public init(
        id: String, provider: PaperSource.Provider, title: String, authors: [String] = [], journal: String? = nil,
        year: Int? = nil, doi: String? = nil, pmid: String? = nil, abstract: String? = nil, pdfURL: URL? = nil,
        storedPDFAttachmentKey: String? = nil, storedPDFReachable: Bool = false, pageURL: URL? = nil, dateJoined: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.authors = authors
        self.journal = journal
        self.year = year
        self.doi = doi
        self.pmid = pmid
        self.abstract = abstract
        self.pdfURL = pdfURL
        self.storedPDFAttachmentKey = storedPDFAttachmentKey
        self.storedPDFReachable = storedPDFReachable
        self.pageURL = pageURL
        self.dateJoined = dateJoined
    }

    /// A field a later build adds must not make this build drop the record, so every field but the identity reads
    /// as absent when it is missing.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        provider = (try? box.decode(PaperSource.Provider.self, forKey: .provider)) ?? .zotero
        title = try box.decode(String.self, forKey: .title)
        authors = (try? box.decodeIfPresent([String].self, forKey: .authors)) ?? []
        journal = try? box.decodeIfPresent(String.self, forKey: .journal)
        year = try? box.decodeIfPresent(Int.self, forKey: .year)
        doi = try? box.decodeIfPresent(String.self, forKey: .doi)
        pmid = try? box.decodeIfPresent(String.self, forKey: .pmid)
        abstract = try? box.decodeIfPresent(String.self, forKey: .abstract)
        pdfURL = try? box.decodeIfPresent(URL.self, forKey: .pdfURL)
        storedPDFAttachmentKey = try? box.decodeIfPresent(String.self, forKey: .storedPDFAttachmentKey)
        storedPDFReachable = (try? box.decodeIfPresent(Bool.self, forKey: .storedPDFReachable)) ?? false
        pageURL = try? box.decodeIfPresent(URL.self, forKey: .pageURL)
        dateJoined = try? box.decodeIfPresent(Date.self, forKey: .dateJoined)
    }

    /// The Zotero user whose own library the paper came from (entry ids are `zotero:user:<id>:<key>`).
    public var zoteroUserID: Int? {
        let parts = id.split(separator: ":")
        guard parts.count == 4, parts[0] == "zotero", parts[1] == "user" else { return nil }
        return Int(parts[2])
    }

    /// The address a PDF fetched from Zotero's file storage is kept under: the paper's own public address when it has
    /// one, else a local `zotero-file://` name built from the attachment key. Never the API address, which names the
    /// listener's Zotero user ID, so neither Diagnostics nor a shared item ever carries it (#853). The Library index
    /// matches it, so the paper reads In Library after a relaunch.
    public var storedPDFSourceURL: URL? {
        if let pageURL { return pageURL }
        guard let key = storedPDFAttachmentKey, !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return URL(string: "zotero-file://attachment/\(key)")
    }

    public var status: PaperEntryStatus {
        if pdfURL != nil || (storedPDFReachable && storedPDFAttachmentKey != nil) { return .pdf }
        if abstract?.contains(where: { !$0.isWhitespace }) == true { return .abstractOnly }
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

    /// "Smith, Jones et al. · Nature · 2021", the paper row's second line. Parts the record lacks are left out.
    public var citationLine: String {
        [authorLine, journal ?? "", year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A followed reading list as the store keeps it: its own record kind, `paper_source`, in the generic records table,
/// with no item id. It touches neither the feed subscriptions nor `SourceIdentityKind`, so an older build, which reads
/// every record by an explicit kind, never sees it. "In Library" is never stored: it is worked out when a screen opens.
public struct PaperSourceRecord: Codable, Equatable, Identifiable, Sendable {
    public static let recordKind = "paper_source"
    /// The newest papers a list keeps.
    public static let maximumEntries = 500

    /// `source.identifier`.
    public var id: String
    public var source: PaperSource
    /// The link the listener pasted, or the API address of a list picked from Your collections.
    public var link: String
    /// The collection's or library's name.
    public var title: String
    public var followedAt: Date
    /// The last time the listener opened the list's screen. Nil until they do.
    public var lastOpenedAt: Date?
    public var lastRefreshedAt: Date?
    public var isQuiet: Bool
    /// How many papers the list holds, as the provider counts them (it can be more than `entries` keeps).
    public var totalCount: Int?
    /// Newest joined first, at most `maximumEntries`.
    public var entries: [PaperEntry]

    public init(
        source: PaperSource, link: String, title: String, followedAt: Date, lastOpenedAt: Date? = nil,
        lastRefreshedAt: Date? = nil, isQuiet: Bool = false, totalCount: Int? = nil, entries: [PaperEntry] = []
    ) {
        id = source.identifier
        self.source = source
        self.link = link
        self.title = title
        self.followedAt = followedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.isQuiet = isQuiet
        self.totalCount = totalCount
        self.entries = Self.capped(entries)
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = try box.decode(PaperSource.self, forKey: .source)
        id = (try? box.decode(String.self, forKey: .id)) ?? source.identifier
        link = (try? box.decode(String.self, forKey: .link)) ?? ""
        title = (try? box.decode(String.self, forKey: .title)) ?? ""
        followedAt = try box.decode(Date.self, forKey: .followedAt)
        lastOpenedAt = try? box.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        lastRefreshedAt = try? box.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        isQuiet = (try? box.decodeIfPresent(Bool.self, forKey: .isQuiet)) ?? false
        totalCount = try? box.decodeIfPresent(Int.self, forKey: .totalCount)
        // One paper that doesn't read is dropped; the list stands.
        let lossy = (try? box.decodeIfPresent([LossyEntry].self, forKey: .entries)) ?? []
        entries = lossy.compactMap(\.value)
    }

    private struct LossyEntry: Decodable {
        var value: PaperEntry?
        init(from decoder: Decoder) throws { value = try? PaperEntry(from: decoder) }
    }

    /// Papers joined since the listener last opened the list (or, before that, since they followed it), so a list
    /// followed with 12 papers reads "12 papers" until something joins it.
    public var newCount: Int {
        let since = lastOpenedAt ?? followedAt
        return entries.filter { ($0.dateJoined ?? .distantPast) > since }.count
    }

    /// The paper count the row shows: the provider's own when it gave one.
    public var paperCount: Int { max(totalCount ?? 0, entries.count) }

    /// The newest date a paper joined the list; Following sorts the row by it, never by a paper's publication year.
    /// Before any paper is dated, the follow itself.
    public var newestJoinedAt: Date {
        entries.compactMap(\.dateJoined).max() ?? followedAt
    }

    /// Replaces the papers with a fresh read. Papers the provider no longer lists leave; the newest 500 stay.
    public mutating func apply(title freshTitle: String?, entries fresh: [PaperEntry], totalCount count: Int?, at date: Date) {
        if let freshTitle, !freshTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = freshTitle }
        entries = Self.capped(fresh)
        totalCount = count
        lastRefreshedAt = date
    }

    public static func capped(_ entries: [PaperEntry]) -> [PaperEntry] {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.id).inserted }
        let ordered = unique.enumerated().sorted { lhs, rhs in
            let left = lhs.element.dateJoined ?? .distantPast
            let right = rhs.element.dateJoined ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        return Array(ordered.prefix(maximumEntries))
    }
}

/// Where a followed list is kept. `SQLiteSessionStore` keeps them (SessionKitPersistence); tests pass a dictionary.
public protocol PaperSourceStoring: Sendable {
    func loadPaperSources() throws -> [PaperSourceRecord]
    func savePaperSource(_ record: PaperSourceRecord) throws
    func deletePaperSource(id: String) throws
    /// Reads one list, changes it and saves it as one step, so a refresh, an open, Quiet and Unfollow landing at the
    /// same moment never undo each other (an unfollowed list is never brought back). Nil when it isn't followed.
    @discardableResult
    func updatePaperSource(id: String, _ change: (inout PaperSourceRecord) throws -> Void) throws -> PaperSourceRecord?
}

/// One followed reading list on Following: "PHIL 330 readings" over "Zotero · 4 new papers", with a chevron and no ▶,
/// since nothing plays until a paper is added.
public struct PaperSourceRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var providerName: String
    public var paperCount: Int
    public var newCount: Int
    public var newestJoinedAt: Date
    public var isQuiet: Bool

    public init(record: PaperSourceRecord) {
        id = record.id
        title = record.title.isEmpty ? (record.source.provider == .pubmed ? "PubMed search" : "Zotero library") : record.title
        providerName = record.source.provider == .pubmed ? "PubMed" : "Zotero"
        paperCount = record.paperCount
        newCount = record.isQuiet ? 0 : record.newCount
        newestJoinedAt = record.newestJoinedAt
        isQuiet = record.isQuiet
    }

    /// "Zotero · 4 new papers", or "Zotero · 12 papers" when nothing is new.
    public var detail: String {
        if newCount > 0 { return "\(providerName) · \(newCount) new \(newCount == 1 ? "paper" : "papers")" }
        return "\(providerName) · \(paperCount) \(paperCount == 1 ? "paper" : "papers")"
    }

    /// "PHIL 330 readings, papers from Zotero, 4 new".
    public var accessibilityLabel: String {
        let count = newCount > 0 ? "\(newCount) new" : "\(paperCount) \(paperCount == 1 ? "paper" : "papers")"
        return "\(title), papers from \(providerName), \(count)"
    }

    /// The followed lists as Following shows them: not Quiet, newest joined first. Ties keep the follow order.
    public static func visible(_ records: [PaperSourceRecord]) -> [PaperSourceRow] {
        ordered(records.filter { !$0.isQuiet })
    }

    /// Quiet lists, for the Quiet group at the bottom, in the same order.
    public static func quiet(_ records: [PaperSourceRecord]) -> [PaperSourceRow] {
        ordered(records.filter(\.isQuiet))
    }

    private static func ordered(_ records: [PaperSourceRecord]) -> [PaperSourceRow] {
        records.enumerated().sorted { lhs, rhs in
            let (l, r) = (lhs.element.newestJoinedAt, rhs.element.newestJoinedAt)
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map { PaperSourceRow(record: $0.element) }
    }
}
