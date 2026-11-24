import Foundation
import SessionKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// #4341: reading a followed Zotero list over the network. The phone asks Zotero's API host directly, as it asks any
// feed; nothing goes through the product server. The transport is passed in, so the app gives it a URLSession and the
// tests give it the real replies saved under Contracts/fixtures/feeds.

/// One reply, as much of it as the reader needs.
public struct PaperFetchReply: Sendable {
    public var status: Int
    public var data: Data
    /// Zotero's `Total-Results` header: how many results the request matched in all.
    public var totalResults: Int?

    public init(status: Int, data: Data, totalResults: Int? = nil) {
        self.status = status
        self.data = data
        self.totalResults = totalResults
    }
}

public typealias PaperTransport = @Sendable (URLRequest) async throws -> PaperFetchReply

/// Why a list could not be read, in the words the screen shows. None of them carries the address, the reply or the key.
public enum PaperFetchProblem: Error, Equatable, Sendable {
    case offline
    /// A group library that is not public (403 with no key).
    case privateLibrary
    /// The listener's own library answered 403: the key was revoked, mistyped or lacks access.
    case keyRefused
    case notFound
    /// 429 or 503: Zotero asked us to slow down.
    case busy
    /// Any other failure: a timeout, a 5xx, a reply that isn't Zotero's JSON or PubMed's RSS.
    case unreachable

    public func message(zoteroConnected: Bool) -> String {
        message(zoteroConnected: zoteroConnected, provider: .zotero)
    }

    /// The words for a list of this provider: a PubMed search never reads as a Zotero problem.
    public func message(zoteroConnected: Bool, provider: PaperSource.Provider) -> String {
        if provider == .pubmed {
            switch self {
            case .offline: return "You're offline. Try again when you're connected."
            case .notFound, .privateLibrary, .keyRefused:
                return "PubMed couldn't find that search. Make a new link with Create RSS."
            case .busy: return "PubMed is busy. Try again in a few minutes."
            case .unreachable: return "PubMed couldn't be reached. Try again later."
            }
        }
        switch self {
        case .offline: return "You're offline. Try again when you're connected."
        case .privateLibrary:
            return zoteroConnected
                ? "That Zotero group is private. Only public groups and your own library can be followed."
                : PaperFeedLinkProblem.zoteroPrivateLibrary.message(zoteroConnected: false)
        case .keyRefused: return "Zotero didn't accept that key."
        case .notFound: return PaperFeedLinkProblem.zoteroNotUnderstood.message
        case .busy: return "Zotero is busy. Try again in a few minutes."
        case .unreachable: return "Zotero couldn't be reached. Try again later."
        }
    }
}

/// What one read of a list gave.
public struct PaperSourceSnapshot: Equatable, Sendable {
    /// The collection's or library's name; nil when its record couldn't be read (the papers still count).
    public var title: String?
    /// Newest joined first, at most `PaperSourceRecord.maximumEntries`.
    public var entries: [PaperEntry]
    public var totalCount: Int?
}

public struct PaperSourceFetcher: Sendable {
    /// 5 pages of 100: the 500 newest papers a list keeps (Zotero sorts them by `dateAdded`, newest first).
    public static let maximumItemPages = PaperSourceRecord.maximumEntries / ZoteroPaperAPI.pageSize
    /// A list's attachments are read up to 1,000; a paper whose PDF is past that reads as abstract or link only.
    public static let maximumAttachmentPages = 10
    public static let maximumCollectionPages = 5
    /// What the listener's own library is called when no collection is picked.
    public static let ownLibraryTitle = "My Library"

    let transport: PaperTransport

    public init(transport: @escaping PaperTransport) {
        self.transport = transport
    }

    /// Reads a list: its papers (with each paper's attachments, which decide PDF, Abstract only or Link only) and its
    /// name. The key goes only with the listener's own library.
    public func fetch(_ source: PaperSource, apiKey: String?) async throws(PaperFetchProblem) -> PaperSourceSnapshot {
        let library: ZoteroPaperAPI.Library
        let collectionKey: String?
        switch source {
        case .zoteroGroup(let groupID, let key): (library, collectionKey) = (.group(groupID), key)
        case .zoteroUser(let userID, let key): (library, collectionKey) = (.user(userID), key)
        case .pubMedRSS: return try await fetchPubMed(source)
        }
        let key = source.needsZoteroKey ? apiKey : nil
        var itemPages: [Data] = []
        var total: Int?
        for page in 0..<Self.maximumItemPages {
            let start = page * ZoteroPaperAPI.pageSize
            let reply = try await get(ZoteroPaperAPI.itemsURL(library: library, collectionKey: collectionKey, start: start), key: key, source: source)
            if page == 0 { total = reply.totalResults }
            guard let count = Self.arrayCount(reply.data) else { throw .unreachable }
            itemPages.append(reply.data)
            if count < ZoteroPaperAPI.pageSize { break }
            if let total, start + count >= total { break }
        }
        var attachmentPages: [Data] = []
        for page in 0..<Self.maximumAttachmentPages {
            let start = page * ZoteroPaperAPI.pageSize
            // Attachments only decide a paper's status; a failed page leaves those papers abstract or link only.
            guard let reply = try? await get(ZoteroPaperAPI.attachmentsURL(library: library, collectionKey: collectionKey, start: start), key: key, source: source),
                  let count = Self.arrayCount(reply.data)
            else { break }
            attachmentPages.append(reply.data)
            if count < ZoteroPaperAPI.pageSize { break }
            if let total = reply.totalResults, start + count >= total { break }
        }
        var entries: [PaperEntry] = []
        for page in itemPages {
            guard let read = try? ZoteroPaperReader.read(items: page, attachments: attachmentPages, library: library) else {
                throw .unreachable
            }
            entries += read.entries
        }
        return PaperSourceSnapshot(
            title: await title(library: library, collectionKey: collectionKey, key: key, source: source),
            entries: PaperSourceRecord.capped(entries),
            totalCount: total
        )
    }

    /// #5201: a PubMed search's RSS, one request with no key and no cookie. The feed holds only the newest items its
    /// link asks for, so the count is what it gave.
    private func fetchPubMed(_ source: PaperSource) async throws(PaperFetchProblem) -> PaperSourceSnapshot {
        var request = URLRequest(url: source.pageURL())
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("application/rss+xml, application/xml;q=0.9", forHTTPHeaderField: "Accept")
        await PubMedRequestPacer.shared.wait()
        let reply: PaperFetchReply
        do {
            reply = try await transport(request)
        } catch {
            throw Self.problem(for: error)
        }
        guard (200..<300).contains(reply.status) else { throw Self.problem(status: reply.status, source: source) }
        guard let page = try? PubMedPaperReader.read(reply.data) else { throw .unreachable }
        return PaperSourceSnapshot(title: page.title, entries: PaperSourceRecord.capped(page.entries), totalCount: nil)
    }

    /// The listener's own collections, for "Your collections", and the library's name for "Connected as". Also the
    /// check Connect makes: a refused key answers `.keyRefused`.
    public func collections(userID: Int, apiKey: String) async throws(PaperFetchProblem) -> (libraryName: String?, collections: [ZoteroCollection]) {
        let source = PaperSource.zoteroUser(userID: userID, collectionKey: nil)
        var all: [ZoteroCollection] = []
        var name: String?
        for page in 0..<Self.maximumCollectionPages {
            let reply = try await get(ZoteroPaperAPI.collectionsURL(library: .user(userID), start: page * ZoteroPaperAPI.pageSize), key: apiKey, source: source)
            guard let count = Self.arrayCount(reply.data), let read = try? ZoteroCollectionReader.collections(reply.data) else {
                throw .unreachable
            }
            if name == nil { name = ZoteroCollectionReader.libraryName(reply.data) }
            all += read
            if count < ZoteroPaperAPI.pageSize { break }
        }
        if name == nil {
            // A library with no collections names itself in its items too.
            let items = try? await get(ZoteroPaperAPI.itemsURL(library: .user(userID), collectionKey: nil), key: apiKey, source: source)
            name = items.flatMap { ZoteroCollectionReader.libraryName($0.data) }
        }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.key).inserted }
        return (name, unique.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.key < rhs.key : order == .orderedAscending
        })
    }

    private func title(library: ZoteroPaperAPI.Library, collectionKey: String?, key: String?, source: PaperSource) async -> String? {
        if let collectionKey {
            let reply = try? await get(ZoteroPaperAPI.collectionURL(library: library, collectionKey: collectionKey), key: key, source: source)
            return reply.flatMap { ZoteroCollectionReader.name($0.data) }
        }
        switch library {
        case .group(let groupID):
            let reply = try? await get(ZoteroPaperAPI.groupURL(groupID: groupID), key: nil, source: source)
            return reply.flatMap { ZoteroCollectionReader.name($0.data) }
        case .user:
            return Self.ownLibraryTitle
        }
    }

    private func get(_ url: URL, key: String?, source: PaperSource) async throws(PaperFetchProblem) -> PaperFetchReply {
        let reply: PaperFetchReply
        do {
            reply = try await transport(ZoteroPaperAPI.request(url, apiKey: key))
        } catch {
            throw Self.problem(for: error)
        }
        if (200..<300).contains(reply.status) { return reply }
        throw Self.problem(status: reply.status, source: source)
    }

    static func problem(status: Int, source: PaperSource) -> PaperFetchProblem {
        if source.provider == .pubmed {
            switch status {
            case 404, 410: return .notFound
            case 429, 503: return .busy
            default: return .unreachable
            }
        }
        switch status {
        case 401, 403: return source.needsZoteroKey ? .keyRefused : .privateLibrary
        case 404, 410: return .notFound
        case 429, 503: return .busy
        default: return .unreachable
        }
    }

    static func problem(for error: Error) -> PaperFetchProblem {
        if let problem = error as? PaperFetchProblem { return problem }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .unreachable
            }
        }
        return .unreachable
    }

    /// How many rows a JSON array holds, nil when the bytes aren't one.
    static func arrayCount(_ data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data)) .flatMap { $0 as? [Any] }?.count
    }
}

/// NCBI asks a client with no API key for at most three requests a second. Refreshing several PubMed searches at once
/// (a pull on Following) spaces its requests by this much; a lone follow or refresh doesn't wait.
actor PubMedRequestPacer {
    static let shared = PubMedRequestPacer()
    static let minimumSpacing: Duration = .milliseconds(340)

    private var last: ContinuousClock.Instant?

    func wait() async {
        let clock = ContinuousClock()
        if let last {
            let next = last.advanced(by: Self.minimumSpacing)
            if clock.now < next { try? await clock.sleep(until: next) }
        }
        last = clock.now
    }
}
