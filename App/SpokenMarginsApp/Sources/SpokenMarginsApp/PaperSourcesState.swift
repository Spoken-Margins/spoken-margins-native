import Foundation
import SessionKit
import SessionKitFeeds
import SessionKitPersistence

/// The listener's Zotero user ID, key and library name, in the Keychain (service `com.spokenmargins.zotero`, the Read
/// Later pattern). Tests pass an in-memory store so they never touch it. The key leaves the Keychain only for a request
/// to api.zotero.org (`ZoteroPaperAPI.request`), and is never written to a log or to Diagnostics.
struct ZoteroCredentialStore: Sendable {
    static let service = "com.spokenmargins.zotero"
    var load: @Sendable (_ account: String) -> String?
    var save: @Sendable (_ value: String, _ account: String) -> Void

    static let keychain = ZoteroCredentialStore(
        load: { KeychainStore.load(service: ZoteroCredentialStore.service, account: $0) },
        save: { KeychainStore.save($0, service: ZoteroCredentialStore.service, account: $1) }
    )

    func apiKey() -> String? {
        guard let key = load("apiKey"), !key.isEmpty else { return nil }
        return key
    }

    func connection() -> ZoteroConnection? {
        guard apiKey() != nil, let id = load("userID").flatMap(Int.init) else { return nil }
        return ZoteroConnection(userID: id, libraryName: load("libraryName"))
    }

    func keep(userID: Int, apiKey: String, libraryName: String?) {
        save(String(userID), "userID")
        save(apiKey, "apiKey")
        save(libraryName ?? "", "libraryName")
    }

    /// An empty value deletes the Keychain entry.
    func clear() {
        for account in ["apiKey", "userID", "libraryName"] { save("", account) }
    }
}

/// The session paper sources fetch through: no cookies, no cache, no shared credentials, and a redirect keeps the key
/// only on Zotero's own API host (a stored file is served from another host).
final class PaperSourceSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(ZoteroPaperAPI.redirectRequest(request))
    }
}

enum PaperSourceSession {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: PaperSourceSessionDelegate(), delegateQueue: nil)
    }()

    static let transport: PaperTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard data.count <= 50 * 1_024 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
        return PaperFetchReply(
            status: http.statusCode, data: data,
            totalResults: http.value(forHTTPHeaderField: "Total-Results").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }
}

/// Followed reading lists (#4341): what Following, Follow papers, the paper screen and Settings › Zotero read. The rules
/// are `PaperSourceFollowing`, `PaperSourceScreen` and `PaperEntryImportRoute` in SessionKitFeeds, host-tested; this
/// object runs them off the main thread, publishes the records, and adds papers through the model's existing imports.
/// It lives apart from `Gate1AppModel`, which only lends it its store, banners and imports.
@MainActor
final class PaperSourcesState: ObservableObject {
    static let shared = PaperSourcesState()

    @Published private(set) var records: [PaperSourceRecord] = []
    @Published private(set) var loaded = false
    @Published private(set) var isRefreshing = false
    /// Papers whose Add is under way, by entry id.
    @Published private(set) var adding: Set<String> = []
    /// Papers whose PDF couldn't be fetched this run.
    @Published private(set) var pdfFailed: Set<String> = []
    /// Papers added this run, entry id to item id, before a fresh Library index knows them.
    @Published private(set) var added: [String: String] = [:]
    @Published private(set) var connection: ZoteroConnection?
    @Published private(set) var collections: [ZoteroCollection] = []
    @Published private(set) var collectionsProblem: String?
    @Published private(set) var isLoadingCollections = false
    /// Why a list's last read failed, by list id, until a read succeeds: its screen says so above the papers.
    @Published private(set) var refreshProblems: [String: PaperFetchProblem] = [:]

    private let credentials: ZoteroCredentialStore
    private let transport: PaperTransport
    private var storeForRecords: SQLiteSessionStore?
    /// Bumped by each read of the stored lists; only the newest read publishes, so a slow older read never wins.
    private var readGeneration = 0
    /// The key, read from the Keychain once at launch and kept in step with Connect and Disconnect, so a refresh or
    /// an Add never reads the Keychain on the main thread again.
    private var apiKey: String?

    init(credentials: ZoteroCredentialStore = .keychain, transport: PaperTransport? = nil) {
        self.credentials = credentials
        self.transport = transport ?? PaperSourceSession.transport
        connection = credentials.connection()
        apiKey = connection == nil ? nil : credentials.apiKey()
    }

    var visibleRows: [PaperSourceRow] { PaperSourceRow.visible(records) }
    var quietRows: [PaperSourceRow] { PaperSourceRow.quiet(records) }

    func record(id: String) -> PaperSourceRecord? { records.first { $0.id == id } }

    private func following(_ store: SQLiteSessionStore) -> PaperSourceFollowing {
        PaperSourceFollowing(store: store, fetcher: PaperSourceFetcher(transport: transport))
    }

    private var fetcher: PaperSourceFetcher { PaperSourceFetcher(transport: transport) }

    // MARK: Reading the stored lists

    /// Reads the stored lists once per store, off the main thread.
    func load(model: Gate1AppModel) async {
        // No store: there are no lists to read, and Following mustn't wait for them.
        guard let store = model.store else { loaded = true; return }
        if loaded, storeForRecords === store { return }
        await reload(store: store)
    }

    private func reload(store: SQLiteSessionStore) async {
        readGeneration += 1
        let generation = readGeneration
        let read = await Task.detached(priority: .userInitiated) { (try? store.loadPaperSources()) ?? [] }.value
        guard generation == readGeneration else { return }
        storeForRecords = store
        if read != records { records = read }
        loaded = true
    }

    /// Following opened or was pulled: read the lists that are due, one at a time (Zotero asks for no more than four
    /// requests at once). A failure keeps the last snapshot; Following stays quiet about it, and the list's own screen
    /// says why (offline, a key Zotero no longer accepts). `only` limits a pull on one list's screen to that list.
    func refresh(model: Gate1AppModel, pulled: Bool, only id: String? = nil) async {
        await load(model: model)
        guard let store = model.store, !isRefreshing else { return }
        let candidates = id.map { id in records.filter { $0.id == id } } ?? records
        let due = PaperSourceFollowing.due(candidates, connectedUserID: connection?.userID, now: Date(), pulled: pulled)
        guard !due.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let following = following(store)
        let key = apiKey
        for record in due {
            let result = await Task.detached(priority: .utility) {
                await following.refresh(record, apiKey: record.source.needsZoteroKey ? key : nil, now: Date())
            }.value
            switch result {
            case .success: refreshProblems[record.id] = nil
            case .failure(let problem): refreshProblems[record.id] = problem
            }
        }
        await reload(store: store)
    }

    /// The line a list's screen shows above its papers when its last read failed: the Design's offline line, or the
    /// fetch problem's own words ("Zotero didn't accept that key." after a key is revoked).
    func refreshProblemLine(id: String) -> String? {
        guard let problem = refreshProblems[id] else { return nil }
        if problem == .offline { return PaperSourceScreen.offlineSnapshotLine }
        return problem.message(zoteroConnected: connection != nil)
    }

    // MARK: Follow

    enum FollowResult: Equatable {
        case followed
        /// The line under the field (none when the app already said why); the field keeps the text.
        case problem(String?)
    }

    /// Follow on the Follow papers screen. A link that is not a reading list goes to today's feed follow unchanged.
    func follow(pasted: String, model: Gate1AppModel) async -> FollowResult {
        guard let store = model.store else { return .problem("Couldn't save that. Try again.") }
        let following = following(store)
        let key = apiKey
        let connected = connection != nil
        let outcome = await Task.detached(priority: .userInitiated) {
            await following.follow(pasted: pasted, apiKey: key, zoteroConnected: connected, now: Date())
        }.value
        switch outcome {
        case .notAPaperLink:
            model.followedSourceURL = pasted
            switch await model.followTypedLink() {
            case .followed: return .followed
            case .needsChoice: return .problem(Gate1AppModel.chooseFeedMessage)
            case .stopped(let line): return .problem(line)
            }
        case .rejected(let line):
            return .problem(line)
        case .alreadyFollowing(let record):
            await reload(store: store)
            model.reportConfirmation("You already follow \(record.title).")
            return .followed
        case .followed(let record):
            await reload(store: store)
            announceFollowed(record, model: model)
            return .followed
        }
    }

    /// A collection picked from Your collections, or the whole library.
    func follow(collection: ZoteroCollection?, model: Gate1AppModel) async -> FollowResult {
        guard let connection, let store = model.store else { return .problem(PaperFetchProblem.keyRefused.message(zoteroConnected: false)) }
        let source = PaperSource.zoteroUser(userID: connection.userID, collectionKey: collection?.key)
        let following = following(store)
        let key = apiKey
        let outcome = await Task.detached(priority: .userInitiated) {
            await following.follow(source: source, link: source.pageURL().absoluteString, apiKey: key, zoteroConnected: true, now: Date())
        }.value
        switch outcome {
        case .followed(let record):
            await reload(store: store)
            announceFollowed(record, model: model)
            return .followed
        case .alreadyFollowing:
            return .followed
        case .rejected(let line):
            return .problem(line)
        case .notAPaperLink:
            return .problem(PaperFetchProblem.unreachable.message(zoteroConnected: true))
        }
    }

    /// "Following PHIL 330 readings." with Undo, as following a show does.
    private func announceFollowed(_ record: PaperSourceRecord, model: Gate1AppModel) {
        let id = record.id
        model.presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: "Following \(record.title).",
            action: UserFeedbackEvent.Action(
                title: FollowingDismissMessages.undoTitle,
                accessibilityLabel: "Undo following \(record.title)",
                identifier: "papers.follow.undo",
                perform: { [weak self, weak model] in
                    guard let self, let model else { return }
                    Task { await self.unfollow(id: id, model: model, offerUndo: false) }
                }
            )
        ))
    }

    // MARK: The list's own screen

    func markOpened(id: String, model: Gate1AppModel) async {
        guard let store = model.store else { return }
        let following = following(store)
        _ = await Task.detached(priority: .utility) { try? following.markOpened(id: id, now: Date()) }.value
        await reload(store: store)
    }

    func setQuiet(id: String, _ quiet: Bool, model: Gate1AppModel) async {
        guard let store = model.store else { return }
        let following = following(store)
        _ = await Task.detached(priority: .userInitiated) { try? following.setQuiet(id: id, quiet) }.value
        await reload(store: store)
    }

    /// Unfollow leaves every added paper in the Library; the banner offers Undo.
    func unfollow(id: String, model: Gate1AppModel, offerUndo: Bool = true) async {
        guard let store = model.store else { return }
        let following = following(store)
        let removed = await Task.detached(priority: .userInitiated) { try? following.unfollow(id: id) }.value
        await reload(store: store)
        guard offerUndo, let removed else { return }
        model.presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: FollowListWords.unfollowedBanner(showTitle: removed.title, wasInAList: false),
            action: UserFeedbackEvent.Action(
                title: FollowingDismissMessages.undoTitle,
                accessibilityLabel: FollowingRowActions.undoUnfollowAccessibilityLabel(showTitle: removed.title),
                identifier: "papers.unfollow.undo",
                perform: { [weak self, weak model] in
                    guard let self, let model, let store = model.store else { return }
                    let following = self.following(store)
                    Task {
                        _ = await Task.detached(priority: .userInitiated) { try? following.restore(removed) }.value
                        await self.reload(store: store)
                    }
                }
            )
        ))
    }

    /// The Library's DOI and address index, built off the main thread when a list's screen opens.
    func libraryIndex(model: Gate1AppModel) async -> PaperLibraryIndex? {
        guard let store = model.store else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PaperLibraryIndex(items: (try? store.listItems()) ?? [])
        }.value
    }

    func rows(for record: PaperSourceRecord, index: PaperLibraryIndex?) -> [PaperSourceScreen.Row] {
        PaperSourceScreen.rows(record: record, index: index, added: added, adding: adding, pdfFailed: pdfFailed,
                               connectedUserID: connection?.userID)
    }

    // MARK: Add

    /// Add on one paper: its PDF, else its abstract as a short text item; never playback, never a second copy. Two taps
    /// import once.
    func add(_ entry: PaperEntry, model: Gate1AppModel) async {
        guard !adding.contains(entry.id), added[entry.id] == nil else { return }
        var entry = entry
        if entry.zoteroUserID == nil || entry.zoteroUserID != connection?.userID { entry.storedPDFReachable = false }
        adding.insert(entry.id)
        defer { adding.remove(entry.id) }
        let citation: @Sendable (PDFBibliography?) -> PDFBibliography? = { [entry] extracted in
            PaperCitation.merged(extracted: extracted, entry: entry)
        }
        var route = PaperEntryImportRoute.route(for: entry, existingItemId: nil)
        var pdfFailedFirst = false
        while true {
            switch route {
            case .inLibrary(let itemId):
                added[entry.id] = itemId
                return
            case .pdf(let url):
                if let itemId = try? await model.importRemotePDFInBackground(url: url, onboardingSteps: [.addedOwnSource], bibliography: citation) {
                    added[entry.id] = itemId
                    model.reportConfirmation(PaperAddMessage.added(title: entry.title))
                    return
                }
                pdfFailedFirst = true
                route = PaperEntryImportRoute.afterPDFFailed(for: entry, failed: route)
            case .storedPDF(let attachmentKey):
                if let itemId = await addStoredPDF(entry: entry, attachmentKey: attachmentKey, citation: citation, model: model) {
                    added[entry.id] = itemId
                    model.reportConfirmation(PaperAddMessage.added(title: entry.title))
                    return
                }
                pdfFailedFirst = true
                route = PaperEntryImportRoute.afterPDFFailed(for: entry)
            case .abstract:
                guard let itemId = await addAbstract(entry, model: model) else {
                    model.reportFailure("Couldn't add “\(entry.title)”.")
                    return
                }
                added[entry.id] = itemId
                model.reportConfirmation(pdfFailedFirst ? PaperAddMessage.pdfNeedsLoginAbstractAdded : PaperAddMessage.added(title: entry.title))
                return
            case .open:
                if pdfFailedFirst {
                    pdfFailed.insert(entry.id)
                    model.reportFailure(PaperAddMessage.couldNotGetPDF)
                }
                return
            }
        }
    }

    /// A PDF stored in the listener's own library, fetched with their key (only for a paper of that same user's
    /// library), then imported like any PDF. It is kept under the paper's own address, never the API's, which names
    /// the user ID (#853), and titled with the paper when the PDF names no title.
    private func addStoredPDF(entry: PaperEntry, attachmentKey: String,
                              citation: @escaping @Sendable (PDFBibliography?) -> PDFBibliography?,
                              model: Gate1AppModel) async -> String? {
        guard let connection, connection.userID == entry.zoteroUserID, let key = apiKey,
              let keptAs = entry.storedPDFSourceURL else { return nil }
        let url = ZoteroPaperAPI.fileURL(userID: connection.userID, attachmentKey: attachmentKey)
        let request = ZoteroPaperAPI.request(url, apiKey: key)
        guard let reply = try? await transport(request), (200..<300).contains(reply.status) else { return nil }
        return try? await model.importDownloadedPDF(reply.data, sourceURL: keptAs, fallbackTitle: entry.title,
                                                    onboardingSteps: [.addedOwnSource], bibliography: citation)
    }

    /// The abstract as a short text item titled with the paper, whose source line says "Abstract".
    private func addAbstract(_ entry: PaperEntry, model: Gate1AppModel) async -> String? {
        guard let store = model.store,
              let item = AbstractItemBuilder.item(for: entry, itemId: "paper-\(UUID().uuidString.lowercased())", createdAt: Date())
        else { return nil }
        let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
            do { try store.saveItem(item); return true } catch { return false }
        }.value
        guard saved else { return nil }
        _ = try? await model.reloadLibraryRowsOffMain(store: store)
        model.hangTelemetry.labels.scoped("paperSource.addAbstract") {
            model.scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            model.markOnboardingSteps([.addedOwnSource])
        }
        return item.id
    }

    // MARK: Settings › Zotero

    /// Connect checks the key against the listener's own collections before keeping it, so a wrong key is never stored.
    func connect(userID: String, apiKey: String) async -> String? {
        let typed: (userID: Int, apiKey: String)
        switch ZoteroConnectionInput.validate(userID: userID, apiKey: apiKey) {
        case .failure(let problem): return problem.message
        case .success(let value): typed = value
        }
        let fetcher = fetcher
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(String?, [ZoteroCollection]), PaperFetchProblem> in
            do { return .success(try await fetcher.collections(userID: typed.userID, apiKey: typed.apiKey)) } catch { return .failure(error as? PaperFetchProblem ?? .unreachable) }
        }.value
        switch result {
        case .failure(let problem):
            return problem.message(zoteroConnected: true)
        case .success(let (name, found)):
            credentials.keep(userID: typed.userID, apiKey: typed.apiKey, libraryName: name)
            self.apiKey = typed.apiKey
            refreshProblems = [:]
            connection = ZoteroConnection(userID: typed.userID, libraryName: name)
            collections = found
            collectionsProblem = nil
            return nil
        }
    }

    /// Disconnect forgets the key. Lists already followed from the library stay, with their last papers, and are read
    /// again once it is connected again.
    func disconnect() {
        credentials.clear()
        apiKey = nil
        connection = nil
        collections = []
        collectionsProblem = nil
    }

    /// "Your collections" on Follow papers.
    func loadCollections() async {
        guard let connection, let key = apiKey, !isLoadingCollections else { return }
        isLoadingCollections = true
        defer { isLoadingCollections = false }
        let fetcher = fetcher
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(String?, [ZoteroCollection]), PaperFetchProblem> in
            do { return .success(try await fetcher.collections(userID: connection.userID, apiKey: key)) } catch { return .failure(error as? PaperFetchProblem ?? .unreachable) }
        }.value
        switch result {
        case .success(let (_, found)):
            collections = found
            collectionsProblem = nil
        case .failure(let problem):
            collectionsProblem = problem.message(zoteroConnected: true)
        }
    }
}
