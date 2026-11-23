import SwiftUI
import SessionKit

/// What the drawer's packs need from the app (#4285): quiet follows and one refresh after a Follow all batch, the Not
/// for me snapshot and its hidden sources, and hiding, showing again and unfollowing a catalog source. Nil in tests
/// and previews that have none: Follow all then follows through the drawer's ordinary `follow`, and nothing is hidden.
struct CatalogDrawerPackActions {
    /// Follows without fetching episodes at once; `refreshAfterBatch` runs once after the batch.
    var followQuietly: @MainActor (String) async throws -> String
    var refreshAfterBatch: @MainActor () async -> Void
    /// Awaited before the first list is published, so a hidden source never shows and then snaps away.
    var notForMe: @MainActor () async -> NotForMeSnapshot
    var hiddenSources: @MainActor () async -> [NotForMeStore.HiddenSource]
    /// Hides a source; the second value is its followed source id when the drawer knows one.
    var hide: @MainActor (SourceCatalogEntry, String?) async -> Void
    var showAgain: @MainActor (String) async -> Void
    /// Unfollows the subscription whose feed matches; false when none matched or it failed.
    var unfollow: @MainActor (String) async -> Bool
}

/// The drawer's own toast (#4285 §2a): the app's top banner sits under the sheet and can't be seen.
struct CatalogDrawerToast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (@MainActor () async -> Void)?
}

/// B1 M1: the first-run drawer of popular podcasts. It reads the bundled catalog snapshot
/// (works offline), refreshes from the remote catalog when online, and follows a show in one
/// tap through the app's normal follow path.
@MainActor
final class CatalogDrawerModel: ObservableObject {
    typealias FollowState = CatalogDrawerFollowState

    static let seenKey = "catalogDrawerSeenV1"
    /// Catalog entry id → followed source id, recorded when the drawer follows a show.
    static let followedSourcesKey = "catalogDrawerFollowedSourcesV1"
    /// Set while a friend's file holds the first-run opening back (#3291), so a launch whose friend's item never opened
    /// leaves the drawer to the next one. Cleared when the drawer is seen.
    static let deferredByFriendFileKey = "catalogDrawerDeferredByFriendFileV1"
    /// Set when a friend's file failed and the drawer it withdrew has not come back yet (#3801), so the next launch
    /// still owes the drawer, with nothing held back. Cleared when the drawer is seen.
    static let owedAfterFriendFileFailedKey = "catalogDrawerOwedAfterFriendFileFailedV1"

    @Published var isPresented = false
    /// Packs, Top or a subject (#4285). Every opening resets it: Packs when a pack is visible, otherwise Top.
    @Published var selectedChip: CatalogDrawerChip = .top { didSet { refreshEntries() } }
    /// The subject whose list shows, nil for Top. On the Packs chip the list below is Top's, though packs show.
    var selectedSubject: String? {
        get { selectedChip.listSubject }
        set { selectedChip = newValue.map(CatalogDrawerChip.subject) ?? .top }
    }
    @Published private(set) var catalog: SourceCatalog? { didSet { refreshEntries() } }
    /// What the listener said Not for me to (#4285), read before the first list is published.
    @Published private(set) var notForMeSnapshot: NotForMeSnapshot = .empty { didSet { refreshEntries() } }
    /// The Not for me screen's rows, newest first, read when the screen opens.
    @Published private(set) var hiddenSources: [NotForMeStore.HiddenSource] = []
    @Published private(set) var toast: CatalogDrawerToast?
    /// The Pack and Not for me screens pushed inside the drawer (#4285 PR 9).
    @Published var path: [CatalogDrawerRoute] = []
    /// The rows for the selected subject, refiltered only when the catalog or subject changes
    /// (#246: it was refiltered on every render, including one per Follow tap).
    @Published private(set) var entries: [SourceCatalogEntry] = []
    @Published private(set) var loadError: String?
    @Published private(set) var followStates: [String: FollowState] = [:]
    /// What the drawer's search field is typed (#471). Two or more characters search by name.
    @Published var searchText = "" { didSet { searchTextChanged(from: oldValue) } }
    /// The shows found for the latest answered search. Kept while the next search runs, so typing on
    /// doesn't flash the list empty; nil before the first answer and after a failure or a clear.
    @Published private(set) var searchResults: [SourceCandidate]?
    /// Why the last search failed, in words. The subject list stays usable underneath it.
    @Published private(set) var searchError: String?
    @Published private(set) var isSearchPending = false
    /// The import a "Follow Podcasts in Spoken Margins" Shortcut (#4284) or Following's "Suggested by your AI" row
    /// (#4683) opened, shown over the drawer's list. However it goes (Cancel, Done, back, the sheet closing, a newer
    /// list replacing it), `importClosed` hears about it.
    @Published var shortcutImport: OPMLImportModel? {
        didSet {
            guard let oldValue, oldValue !== shortcutImport else { return }
            importClosed?(oldValue)
        }
    }
    /// Told when an import from a list closes, so the AI's suggestions can drop what it settled (#4683).
    var importClosed: (@MainActor (OPMLImportModel) -> Void)?
    /// The "Got a link from a friend?" card shows on the first-launch opening while the Library holds no friend's packet (#3782).
    @Published private(set) var showsFriendLinkCard = false
    /// Under the card's Paste button when what was pasted holds no share link; cleared by the next paste.
    @Published private(set) var friendLinkNote: String?

    private let store: SourceCatalogStore?
    private let searcher: PodcastNameSearch?
    private var searchTask: Task<Void, Never>?
    private let follow: @MainActor (String) async throws -> String
    private let subscriptions: @MainActor () -> [FeedSubscription]
    private let defaults: UserDefaults
    /// Whether the Library holds a friend's packet, read off the main thread. Nil in tests and previews: no card.
    private let libraryHoldsFriendPacket: (@Sendable () async -> Bool)?
    /// Opens a pasted share link as a tapped one is opened. Nil in tests and previews.
    private let openFriendLink: (@MainActor (URL) -> Void)?
    /// The sheet for a friend's link that failed to open, which this drawer shows while it is up (a sheet from the root
    /// can't present over it). Nil in tests and previews.
    let packetOpenFailures: PacketOpenFailurePresenter?
    private var hasLoaded = false
    /// What Done plays on a fresh install (#2851): the first pick's newest episode or latest post, else the
    /// Welcome sample. Gets the picked sources' ids in tap order, and whether the Welcome sample may stand in when
    /// no pick can start (not when a friend's file held the drawer back, #3796). Nil in tests and previews.
    private let startFirstListen: (@MainActor ([String], Bool) async -> Void)?
    /// Shows tapped in this opening, in tap order. A pick's `sourceId` arrives when its follow lands and is
    /// dropped when the follow fails.
    private var picks: [(key: String, sourceId: String?)] = []
    /// Each pick's follow, in tap order, so Done can wait for them one at a time (#4285 §2f).
    private var followTasks: [(key: String, task: Task<Void, Never>)] = []
    /// An opening began before the catalog loaded: the start chip is chosen when it arrives, so there is no flash
    /// from Top to Packs.
    private var startChipPending = false
    private let packActions: CatalogDrawerPackActions?
    private var toastTask: Task<Void, Never>?
    /// Set by the first-run opening; Done then plays. Opened from Following, Done only closes.
    private var isFirstRunOpening = false
    private var playsOnDismiss = false
    /// When the first-run opening comes: after a friend's file's item, when one arrives (#3291).
    private var welcomeOrder = FirstLaunchWelcomeOrder(drawerOwed: false)
    /// The drawer is closing to make way for a friend's file: not seen, and Done's play doesn't run.
    private var isWithdrawing = false
    /// A friend's file arrived while this opening showed; its item opened underneath, so Done plays nothing over it.
    private var friendFileOpenedUnderneath = false
    /// A friend's file arrived in this run of the app.
    private var hasFriendFileArrived = false
    /// Makes a fresh OPML import (#463) for the drawer and Following; nil hides the entry.
    let makeOPMLImport: (@MainActor () -> OPMLImportModel)?

    init(
        store: SourceCatalogStore?,
        defaults: UserDefaults = .standard,
        subscriptions: @escaping @MainActor () -> [FeedSubscription],
        follow: @escaping @MainActor (String) async throws -> String,
        makeOPMLImport: (@MainActor () -> OPMLImportModel)? = nil,
        searcher: PodcastNameSearch? = nil,
        startFirstListen: (@MainActor ([String], Bool) async -> Void)? = nil,
        libraryHoldsFriendPacket: (@Sendable () async -> Bool)? = nil,
        openFriendLink: (@MainActor (URL) -> Void)? = nil,
        packetOpenFailures: PacketOpenFailurePresenter? = nil,
        packs: CatalogDrawerPackActions? = nil
    ) {
        self.packActions = packs
        self.libraryHoldsFriendPacket = libraryHoldsFriendPacket
        self.openFriendLink = openFriendLink
        self.packetOpenFailures = packetOpenFailures
        self.startFirstListen = startFirstListen
        self.searcher = searcher
        self.store = store
        self.defaults = defaults
        self.subscriptions = subscriptions
        self.follow = follow
        self.makeOPMLImport = makeOPMLImport
    }

    /// The app's drawer: the bundled snapshot plus a cache in Application Support.
    static func makeStore() -> SourceCatalogStore? {
        guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            return configuration
        }())
        return SourceCatalogStore(
            bundledCatalogURL: bundled,
            cacheDirectory: support.appending(path: "SourceCatalog", directoryHint: .isDirectory)
        ) { url, maximumBytes in
            let (data, response) = try await session.data(from: url)
            guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    /// The app's podcast-name search: Apple's public iTunes Search API, one request at a time.
    static func makeSearcher() -> PodcastNameSearch {
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            return configuration
        }())
        return PodcastNameSearch(resolver: ITunesSearchSourceResolver { url, maximumBytes in
            let (data, response) = try await session.data(from: url)
            guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        })
    }

    var subjects: [SourceCatalogSubject] { catalog?.visibleSubjects ?? [] }
    var followedCount: Int { followStates.values.filter { $0 == .followed }.count }
    /// The footer, counting shows and newsletters in their own words (#661).
    var followedSummary: String? {
        let followed = (catalog?.entries ?? []).filter { followStates[$0.id] == .followed }
        return CatalogFollowedSummary.text(followedKinds: followed.map(\.contentKind))
    }

    /// `noteLaunch` with what the model knows once the Library has been bootstrapped.
    func noteLaunch(of model: Gate1AppModel) {
        noteLaunch(libraryWasEmptyAtLaunch: model.libraryWasEmptyAtLaunch, followedSourceCount: model.feedSubscriptions.count)
    }

    /// The first-run opening at once, as for a launch with no friend's file that has settled on the Library.
    func presentIfFirstRun(libraryWasEmptyAtLaunch: Bool, followedSourceCount: Int) {
        noteLaunch(libraryWasEmptyAtLaunch: libraryWasEmptyAtLaunch, followedSourceCount: followedSourceCount)
        settleFirstRun(at: .library)
    }

    /// The root view appeared: whether this launch owes the first-run opening. It waits for `settleFirstRun`, so a
    /// friend's file the app was opened with comes first (#3291).
    func noteLaunch(libraryWasEmptyAtLaunch: Bool, followedSourceCount: Int) {
        let heldBack = defaults.bool(forKey: Self.deferredByFriendFileKey)
        let owedAfterFailure = defaults.bool(forKey: Self.owedAfterFriendFileFailedKey)
        welcomeOrder = FirstLaunchWelcomeOrder(drawerOwed: FirstLaunchWelcomeOrder.drawerOwed(
            libraryWasEmptyAtLaunch: libraryWasEmptyAtLaunch,
            deferredFromEarlierLaunch: heldBack || owedAfterFailure,
            hasSeenDrawer: defaults.bool(forKey: Self.seenKey),
            followedSourceCount: followedSourceCount
        ), owedFromEarlierLaunch: heldBack, owedAfterEarlierFailure: owedAfterFailure)
        // The system can hand the file over before the root view appears.
        if hasFriendFileArrived { recordFriendFileArrival() }
    }

    /// The launch has had time for the system to hand over the file it opened the app with.
    func settleFirstRun(at place: FirstLaunchWelcomeOrder.Place) {
        apply(welcomeOrder.settle(at: place))
    }

    func listenerMoved(to place: FirstLaunchWelcomeOrder.Place) {
        apply(welcomeOrder.moved(to: place))
    }

    /// A friend's file (a packet or a share link) arrived. On a first launch it comes before the drawer (#3291).
    func friendFileArrived() {
        hasFriendFileArrived = true
        showsFriendLinkCard = false
        if isPresented, isFirstRunOpening { friendFileOpenedUnderneath = true }
        recordFriendFileArrival()
    }

    /// The sheet that said a friend's link or file could not be opened has closed. The drawer that file withdrew comes
    /// back: at once on the Library, otherwise at the next visit. Nothing is held back by that file any more, so Done
    /// with nothing picked plays the Welcome sample as on any first launch (#3801).
    func friendFileFailed(at place: FirstLaunchWelcomeOrder.Place) {
        // A failure that lands before the root view notes the launch must not be replayed as an arrival by `noteLaunch`.
        hasFriendFileArrived = false
        apply(welcomeOrder.friendFileFailed(place: place))
        // Still owed (not on the Library yet) but no longer held back by this file: a kill now must not leave the next
        // launch thinking a friend's item is in the Library (the audit on PR #4597).
        if welcomeOrder.carry == .drawerOwed {
            defaults.removeObject(forKey: Self.deferredByFriendFileKey)
            defaults.set(true, forKey: Self.owedAfterFriendFileFailedKey)
        }
        // A drawer that stayed up (the listener had picks) was never withdrawn, so nothing above brought it back: no friend's
        // item came, so Done may play again, and the card returns for another paste (#3782).
        if isPresented, isFirstRunOpening {
            friendFileOpenedUnderneath = false
            refreshFriendLinkCard()
        }
    }

    private func recordFriendFileArrival() {
        apply(welcomeOrder.friendFileArrived(drawerHasPicks: isFirstRunOpening && !picks.isEmpty))
        if welcomeOrder.defersDrawer { defaults.set(true, forKey: Self.deferredByFriendFileKey) }
    }

    private func apply(_ action: FirstLaunchWelcomeOrder.Action) {
        switch action {
        case .none:
            break
        case .presentDrawer:
            // Opened from Following meanwhile, or already seen: the first-run opening has nothing left to do.
            guard !isPresented, !defaults.bool(forKey: Self.seenKey) else { return }
            present()
            isFirstRunOpening = true
            refreshFriendLinkCard()
            // A held-back drawer is owed once: spent as it opens, so a kill with it up doesn't bring it back (#3795).
            // A friend's file arriving while it is up sets the key again (`recordFriendFileArrival`).
            defaults.removeObject(forKey: Self.deferredByFriendFileKey)
            defaults.removeObject(forKey: Self.owedAfterFriendFileFailedKey)
        case .withdrawDrawer:
            isWithdrawing = true
            isPresented = false
        }
    }

    /// The drawer model lives for the whole app run, so each opening drops the follows it
    /// confirmed before: the listener may have unfollowed one in Following since (#646).
    func present() {
        followStates = FollowState.keptOnReopening(followStates)
        picks = []
        followTasks = []
        isFirstRunOpening = false
        playsOnDismiss = false
        isWithdrawing = false
        friendFileOpenedUnderneath = false
        showsFriendLinkCard = false
        friendLinkNote = nil
        searchText = ""
        path = []
        dismissToast()
        if let catalog {
            selectedChip = CatalogDrawerChip.start(in: catalog, notForMe: notForMeSnapshot)
        } else {
            startChipPending = true
        }
        isPresented = true
    }

    /// Decides whether the first-launch card shows: the Library is read off the main thread, and the card appears
    /// only if this opening is still the first-launch one when the answer comes back (#3782).
    private func refreshFriendLinkCard() {
        guard let libraryHoldsFriendPacket else { return }
        Task { @MainActor [weak self] in
            let holds = await libraryHoldsFriendPacket()
            guard let self, self.isPresented, !self.hasFriendFileArrived else { return }
            self.showsFriendLinkCard = FirstLaunchFriendLinkCard.isShown(
                isFirstRunOpening: self.isFirstRunOpening, libraryHoldsFriendPacket: holds)
        }
    }

    /// What the card's system Paste button pasted. A share link is told to the first-launch order as a friend's file
    /// (an untouched drawer withdraws and the Welcome sample is held back; one with picks stays and the item opens under
    /// it), then opened as a tapped link is; a failure brings the drawer back (#3801). Anything else is left alone,
    /// with a line under the button.
    func pasteIntoFriendLinkCard(_ content: String?) {
        switch FirstLaunchFriendLinkCard.pasteResult(for: content) {
        case .open(let url):
            friendLinkNote = nil
            friendFileArrived()
            openFriendLink?(url)
        case .notAFriendLink(let line):
            friendLinkNote = line
        }
    }

    /// A Shortcut passed in podcast feed links (#4284), or the listener tapped the shows their AI suggested
    /// (`origin: .assistant`, #4683): the drawer opens, if it isn't open already, on their import preview. Nothing
    /// is followed until the listener taps Follow there. A second list while the first is still following is
    /// turned away rather than stopping that run. False when there is no import.
    @discardableResult
    func openShortcutImport(feedLinks: [String], origin: OPMLImportModel.Origin = .shortcut) -> Bool {
        guard let makeOPMLImport, shortcutImport?.isFollowing != true else { return false }
        let importer = makeOPMLImport()
        importer.load(feedLinks: feedLinks, origin: origin)
        shortcutImport = importer
        if !isPresented { present() }
        return true
    }

    /// Done. On the first-run opening the sheet closes and the listener's first pick starts playing as it
    /// goes (#2851). A swipe down closes it without playing.
    func finish() {
        // Held back by a friend's file, Done with nothing picked plays nothing: the Library has the friend's episode (#3796).
        let nothingToPlay = !welcomeOrder.playsWelcomeSampleOnClose && picks.isEmpty
        playsOnDismiss = isFirstRunOpening && startFirstListen != nil && !friendFileOpenedUnderneath && !nothingToPlay
        isPresented = false
    }

    /// The sheet closed, however it closed.
    func didDismiss() {
        shortcutImport = nil
        // Withdrawn for a friend's file: it opens again once the friend's item has been opened (#3291).
        if isWithdrawing { isWithdrawing = false; return }
        welcomeOrder.drawerClosed()
        markSeen()
        Task { await playFirstListenIfRequested() }
    }

    /// Run after the sheet has closed, so a Terms sheet the play needs has nothing to collide with. Waits for the
    /// picks in tap order until one has landed, not for all of them (#4285: a Follow all of eight waits for its
    /// first podcast only), then starts the first listen with that pick first. A failed pick is skipped; if every
    /// pick fails, the Welcome sample plays, as with no pick.
    func playFirstListenIfRequested() async {
        guard playsOnDismiss, let startFirstListen else { return }
        playsOnDismiss = false
        var leading: String?
        for (key, task) in followTasks {
            await task.value
            if let sourceId = picks.first(where: { $0.key == key && $0.sourceId != nil })?.sourceId {
                leading = sourceId
                break
            }
        }
        let ids = FirstListenPickOrder.sourceIds(leading: leading, settledInTapOrder: picks.compactMap { $0.sourceId })
        await startFirstListen(ids, welcomeOrder.playsWelcomeSampleOnClose)
    }

    /// Called when the sheet closes, however it closes.
    func markSeen() {
        defaults.set(true, forKey: Self.seenKey)
        defaults.removeObject(forKey: Self.deferredByFriendFileKey)
        defaults.removeObject(forKey: Self.owedAfterFriendFileFailedKey)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let store else {
            loadError = "The podcast list isn't available in this build."
            return
        }
        // Hides are read first, so a hidden source never shows and then snaps away (#4285, the #3753 shape).
        if let packActions { notForMeSnapshot = await packActions.notForMe() }
        do {
            catalog = try await store.current()
        } catch {
            loadError = "The podcast list couldn't be read."
            return
        }
        applyPendingStartChip()
        if case .updated = await store.refresh() {
            catalog = (try? await store.current()) ?? catalog
        }
    }

    private func applyPendingStartChip() {
        guard startChipPending, let catalog else { return }
        startChipPending = false
        selectedChip = CatalogDrawerChip.start(in: catalog, notForMe: notForMeSnapshot)
    }

    /// The stored catalog for Following's kind and subject tags (#485): no refresh, and it
    /// doesn't count as the drawer's load, so opening the drawer still refreshes it.
    func loadSnapshot() async {
        guard catalog == nil, let store, let snapshot = try? await store.current() else { return }
        if catalog == nil { catalog = snapshot }
        applyPendingStartChip()
    }

    var supportsSearch: Bool { searcher != nil }
    /// Whether the field holds enough to search for.
    var isSearching: Bool { searcher != nil && PodcastNameSearch.isSearchable(searchText) }
    /// Search results (or the wait for them) replace the subject list while a search is active. A failed
    /// search leaves the subject list in place under the error.
    var showsSearchResults: Bool { isSearching && (searchResults != nil || isSearchPending) }

    private func searchTextChanged(from previous: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A space typed or removed at the end is not a new search.
        guard query != previous.trimmingCharacters(in: .whitespacesAndNewlines), let searcher else { return }
        searchTask?.cancel()
        searchError = nil
        guard PodcastNameSearch.isSearchable(query) else {
            searchResults = nil
            isSearchPending = false
            return
        }
        isSearchPending = true
        searchTask = Task { [weak self] in
            let outcome = await searcher.search(query)
            guard let self, !Task.isCancelled, self.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            // No outcome while this is still the latest text means nothing will answer it: stop waiting.
            guard let outcome else { self.isSearchPending = false; return }
            self.isSearchPending = false
            switch outcome {
            case .results(let shows):
                self.searchResults = shows
            case .failed(let message):
                self.searchResults = nil
                self.searchError = message
            }
        }
    }

    /// A search result's follow state: the drawer's own, else Following when a subscription has its feed.
    func state(for show: SourceCandidate) -> FollowState? {
        if let state = followStates[show.id] { return state }
        guard let feed = show.feed?.url else { return nil }
        return subscriptions().contains { $0.source.canonicalURL == feed } ? .followed : nil
    }

    /// Follows a search result through the same `follow` the catalog rows use. A show with no public feed
    /// can't be followed; its row says why.
    func followSearchResult(_ show: SourceCandidate) {
        guard let feedURL = show.feed?.url else { return }
        switch state(for: show) {
        case .following, .followed:
            return
        case .failed, nil:
            break
        }
        followStates[show.id] = .following
        picks.append((show.id, nil))
        followTasks.append((show.id, Task { [weak self] in
            guard let self else { return }
            do {
                let sourceId = try await self.follow(feedURL)
                self.settlePick(key: show.id, sourceId: sourceId)
                self.followStates[show.id] = .followed
            } catch {
                self.settlePick(key: show.id, sourceId: nil)
                self.followStates[show.id] = .failed(ListenerErrorText.message(for: error))
            }
        }))
    }

    private func refreshEntries() {
        // Hidden sources are left out of Top and every subject (#4285). Search still finds them.
        let snapshot = notForMeSnapshot
        entries = (catalog?.entries(forSubject: selectedChip.listSubject) ?? []).filter { !snapshot.isHidden($0) }
    }

    func state(for entry: SourceCatalogEntry) -> FollowState? {
        followStates(for: [entry])[entry.id]
    }

    /// Follow state for every row in one pass (#246); rows without a state are left out. The list
    /// asks once per render, so the recorded follows and the subscriptions are read once, not
    /// twice per row. Subscriptions aren't cached: they change in Following without telling
    /// the drawer.
    func followStates(for entries: [SourceCatalogEntry]) -> [String: FollowState] {
        var followed: Set<String> = []
        if let catalog, entries.contains(where: { followStates[$0.id] == nil }) {
            let recorded = defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String] ?? [:]
            followed = CatalogFollowState.followedEntryIds(in: catalog, recordedSourceIds: recorded, subscriptions: subscriptions())
        }
        return FollowState.merged(drawerStates: followStates, liveFollowedEntryIds: followed, entryIds: entries.map(\.id))
    }

    private func recordFollowedSource(_ sourceId: String, for entry: SourceCatalogEntry) {
        var recorded = defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String] ?? [:]
        recorded[entry.id] = sourceId
        defaults.set(recorded, forKey: Self.followedSourcesKey)
    }

    func toggleFollow(_ entry: SourceCatalogEntry) {
        switch state(for: entry) {
        case .following, .followed:
            return
        case .failed, nil:
            break
        }
        _ = startFollow(entry, quietly: false)
    }

    /// Follows one catalog entry as a pick. `quietly` skips the at-once episode fetch (Follow all's later sources).
    /// Returns whether it landed.
    private func startFollow(_ entry: SourceCatalogEntry, quietly: Bool) -> Task<Void, Never> {
        followStates[entry.id] = .following
        picks.append((entry.id, nil))
        let follow = quietly ? (packActions?.followQuietly ?? self.follow) : self.follow
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceId = try await follow(entry.feedURL)
                self.recordFollowedSource(sourceId, for: entry)
                self.settlePick(key: entry.id, sourceId: sourceId)
                self.followStates[entry.id] = .followed
            } catch {
                self.settlePick(key: entry.id, sourceId: nil)
                self.followStates[entry.id] = .failed(ListenerErrorText.message(for: error))
            }
        }
        followTasks.append((entry.id, task))
        return task
    }

    // MARK: Packs (#4285)

    /// Packs with at least one visible source, in §2f order.
    var visiblePacks: [SourceCatalogPack] {
        guard let catalog else { return [] }
        return CatalogPackRanking.visiblePacks(in: catalog, notForMe: notForMeSnapshot)
    }

    /// The chip bar: Packs first when a pack is visible, then Top, then the subjects.
    var showsPacksChip: Bool { !visiblePacks.isEmpty }

    func pack(id: String) -> SourceCatalogPack? { catalog?.packs?.first { $0.id == id } }

    func visibleSources(of pack: SourceCatalogPack) -> [SourceCatalogEntry] {
        guard let catalog else { return [] }
        return CatalogPackRanking.visibleSources(of: pack, in: catalog, notForMe: notForMeSnapshot)
    }

    func footnote(for pack: SourceCatalogPack) -> String {
        guard let catalog else { return "" }
        return CatalogPackRanking.footnote(
            pace: CatalogPackRanking.packPace(of: pack, in: catalog, notForMe: notForMeSnapshot),
            visibleSources: visibleSources(of: pack))
    }

    func paceWords(for entry: SourceCatalogEntry) -> String? {
        guard let catalog else { return nil }
        return CatalogPackPace.rowWords(CatalogPackPace.measure(for: entry, in: catalog))
    }

    func buttonState(for pack: SourceCatalogPack) -> CatalogPackButtonState {
        let sources = visibleSources(of: pack)
        return CatalogPackRanking.buttonState(visibleSourceIds: sources.map(\.id), states: followStates(for: sources))
    }

    /// Follow all, Follow the other N−k, or Retry R. The first source in §2f order fetches its episodes at once;
    /// the rest follow quietly, and one refresh runs after the batch. A second tap while anything from the pack is
    /// in flight does nothing.
    func followAll(_ pack: SourceCatalogPack) {
        let sources = visibleSources(of: pack)
        let targets = CatalogPackFollowPlan.targets(visibleSources: sources, states: followStates(for: sources))
        guard !targets.isEmpty else { return }
        let tasks = targets.enumerated().map { index, entry in startFollow(entry, quietly: index > 0) }
        guard targets.count > 1, let refresh = packActions?.refreshAfterBatch else { return }
        Task {
            for task in tasks.dropFirst() { await task.value }
            await refresh()
        }
    }

    /// "Not for me (H)": how many sources are hidden.
    var hiddenCount: Int { notForMeSnapshot.hiddenFeedKeys.count }

    func reloadHiddenSources() async {
        guard let packActions else { return }
        hiddenSources = await packActions.hiddenSources().sorted { $0.hiddenAt > $1.hiddenAt }
    }

    private func refreshNotForMe() async {
        guard let packActions else { return }
        notForMeSnapshot = await packActions.notForMe()
    }

    /// Show again on the Not for me screen: the hide goes and so does its row. It doesn't follow the source.
    func showAgain(_ source: NotForMeStore.HiddenSource, feedURL: String) async {
        guard let packActions else { return }
        await packActions.showAgain(feedURL)
        await refreshNotForMe()
        await reloadHiddenSources()
    }

    /// The feed a hidden source's row brings back: its catalog entry's, else one rebuilt from the key, which the
    /// store matches by key.
    func feedURL(for source: NotForMeStore.HiddenSource) -> String {
        if let id = source.catalogEntryId, let entry = catalog?.entries.first(where: { $0.id == id }) { return entry.feedURL }
        if let entry = catalog?.entries.first(where: { SourceCatalog.feedKey($0.feedURL) == source.feedKey }) { return entry.feedURL }
        return source.feedKey // the key is itself an https feed address (`FeedURLKey`)
    }

    private func sourceId(for entry: SourceCatalogEntry) -> String? {
        let recorded = defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String] ?? [:]
        if let id = recorded[entry.id] { return id }
        let key = SourceCatalog.feedKey(entry.feedURL)
        return subscriptions().first { SourceCatalog.feedKey($0.source.canonicalURL) == key }?.source.id
    }

    /// Unfollow on a Pack row. Toast: "Unfollowed <title>." Undo follows it again.
    func unfollowFromPack(_ entry: SourceCatalogEntry) {
        guard let packActions else { return }
        Task { [weak self] in
            guard await packActions.unfollow(entry.feedURL), let self else { return }
            self.followStates[entry.id] = nil
            self.showToast(CatalogPackWords.unfollowedToast(title: entry.title)) { [weak self] in
                self?.toggleFollow(entry)
            }
        }
    }

    /// Not for me on a Pack row: it unfollows if followed, then hides the source, so the hide isn't dropped by the
    /// reconcile of a list that still holds it. Undo removes the hide, then follows it again if it was followed.
    func notForMeFromPack(_ entry: SourceCatalogEntry) {
        guard let packActions else { return }
        let wasFollowed = state(for: entry) == .followed
        let sourceId = wasFollowed ? sourceId(for: entry) : nil
        Task { [weak self] in
            if wasFollowed { _ = await packActions.unfollow(entry.feedURL) }
            await packActions.hide(entry, sourceId)
            guard let self else { return }
            self.followStates[entry.id] = nil
            await self.refreshNotForMe()
            self.showToast(CatalogPackWords.hiddenMessage(title: entry.title)) { [weak self] in
                await packActions.showAgain(entry.feedURL)
                await self?.refreshNotForMe()
                if wasFollowed { self?.toggleFollow(entry) }
            }
        }
    }

    /// Shows a toast with Undo for 6 seconds, or until the next one; then the summary comes back.
    func showToast(_ message: String, undo: (@MainActor () async -> Void)?) {
        toastTask?.cancel()
        let toast = CatalogDrawerToast(message: message, undo: undo)
        self.toast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CatalogPackWords.toastSeconds))
            guard !Task.isCancelled, self?.toast?.id == toast.id else { return }
            self?.toast = nil
        }
    }

    func undoToast() {
        guard let toast else { return }
        dismissToast()
        Task { await toast.undo?() }
    }

    private func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    /// A finished follow fills in its pick, keeping the tap order; a failed one is removed. A retry of a
    /// failed row picks again at the time of the retry.
    private func settlePick(key: String, sourceId: String?) {
        guard let index = picks.firstIndex(where: { $0.key == key && $0.sourceId == nil }) else { return }
        if let sourceId { picks[index].sourceId = sourceId } else { picks.remove(at: index) }
    }
}

/// Shows a failed friend's link from inside the drawer, when the drawer has a presenter to show (never in previews).
private struct DrawerPacketOpenFailureSheet: ViewModifier {
    let drawer: CatalogDrawerModel

    func body(content: Content) -> some View {
        if let presenter = drawer.packetOpenFailures {
            content.packetOpenFailureSheet(presenter: presenter, drawer: drawer)
        } else {
            content
        }
    }
}

struct CatalogDrawerView: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel

    var body: some View {
        NavigationStack(path: $drawer.path) {
            VStack(spacing: 0) {
                if drawer.showsFriendLinkCard, !drawer.showsSearchResults {
                    FirstLaunchFriendLinkCardView(drawer: drawer)
                }
                searchFailure
                if drawer.showsSearchResults {
                    searchResults
                } else {
                    subjectBar
                    importLink
                    list
                }
            }
            .background(AppColors.bone)
            .modifier(DrawerSearchField())
            .navigationTitle("Follow a few favourites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { drawer.finish() }
                        .accessibilityIdentifier("catalog.drawer.done")
                }
            }
            .task { await drawer.load() }
            .navigationDestination(for: CatalogDrawerRoute.self) { route in
                switch route {
                case .pack(let id):
                    CatalogPackScreen(packId: id)
                case .notForMe:
                    CatalogNotForMeScreen()
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { drawer.shortcutImport != nil },
                set: { if !$0 { drawer.shortcutImport = nil } }
            )) {
                if let importer = drawer.shortcutImport {
                    // A new list from the Shortcut is a new screen, not the old one's state.
                    OPMLImportScreen(importer: importer).id(ObjectIdentifier(importer))
                }
            }
        }
        .modifier(DrawerPacketOpenFailureSheet(drawer: drawer))
        .accessibilityIdentifier("catalog.drawer")
    }

    @ViewBuilder
    private var searchFailure: some View {
        if drawer.isSearching, let message = drawer.searchError {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("catalog.search.error")
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let shows = drawer.searchResults {
            if shows.isEmpty {
                ContentUnavailableView.search(text: drawer.searchText)
            } else {
                List(shows) { show in
                    CatalogSearchResultRow(show: show, state: drawer.state(for: show)) { drawer.followSearchResult(show) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("catalog.search.results")
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Shown whether or not the podcast list loaded: importing matters most when it didn't (#463).
    @ViewBuilder
    private var importLink: some View {
        if let makeOPMLImport = drawer.makeOPMLImport {
            NavigationLink {
                OPMLImportScreen(importer: makeOPMLImport())
            } label: {
                Label("Import from another app", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("catalog.drawer.importOPML")
        }
    }

    /// Drawn once the catalog has loaded, with the list, so the chip never flashes from Top to Packs (#4285). A
    /// failed load shows no chips.
    @ViewBuilder
    private var subjectBar: some View {
        if drawer.catalog != nil, drawer.loadError == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if drawer.showsPacksChip {
                        subjectChip(.packs, title: CatalogPackWords.packsChipTitle)
                    }
                    subjectChip(.top, title: "Top")
                    ForEach(drawer.subjects) { subject in
                        subjectChip(.subject(subject.id), title: subject.title)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private func subjectChip(_ chip: CatalogDrawerChip, title: String) -> some View {
        let isSelected = drawer.selectedChip == chip
        return Button { drawer.selectedChip = chip } label: {
            CatalogSubjectChipLabel(title: title, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("catalog.subject.\(chip.identifierSuffix)")
    }

    @ViewBuilder
    private var list: some View {
        if let loadError = drawer.loadError {
            ContentUnavailableView("No podcast list", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if drawer.catalog == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if drawer.selectedChip == .packs, drawer.showsPacksChip {
                    Section {
                        EmptyView()
                    } header: {
                        Text(CatalogPackWords.packsHeader)
                            .font(.footnote)
                            .textCase(nil)
                    }
                    // Each pack is its own section with two rows, so a tap on one can never reach the other.
                    ForEach(drawer.visiblePacks, id: \.id) { pack in
                        CatalogPackSection(pack: pack)
                    }
                } else {
                    let states = drawer.followStates(for: drawer.entries)
                    Section {
                        ForEach(drawer.entries) { entry in
                            CatalogDrawerRow(entry: entry, state: states[entry.id]) { drawer.toggleFollow(entry) }
                                .equatable()
                        }
                    } header: {
                        Text(CatalogPackWords.followingNote)
                            .font(.footnote)
                            .textCase(nil)
                    }
                }
                if drawer.hiddenCount > 0 {
                    Section {
                        NavigationLink(value: CatalogDrawerRoute.notForMe) {
                            Label(CatalogPackWords.notForMeRowTitle(hidden: drawer.hiddenCount), systemImage: "eye.slash")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("catalog.drawer.notForMe")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) { CatalogDrawerBottomInset() }
        }
    }
}

/// The Pack and Not for me screens pushed inside the drawer (#4285 PR 9). #4286's quiz adds its own route here.
enum CatalogDrawerRoute: Hashable {
    case pack(String)
    case notForMe
}

/// The drawer's bottom inset: the summary ("Following 2 shows and 1 newsletter"), and in its place for 6 seconds the
/// drawer's own toast with Undo, because the app's top banner sits under the sheet (#4285 §2a).
struct CatalogDrawerBottomInset: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel

    var body: some View {
        if let toast = drawer.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if toast.undo != nil {
                    Button(FollowingDismissMessages.undoTitle) { drawer.undoToast() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("catalog.drawer.toast.undo")
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.bar)
            .accessibilityElement(children: .contain)
        } else if let summary = drawer.followedSummary {
            Text(summary)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.bar)
                .accessibilityIdentifier("catalog.drawer.followedCount")
        }
    }
}

/// Artwork, details and a Follow control for one show. At accessibility text sizes the control stacks under the
/// artwork and text instead of growing beside them and crushing the title (#1934).
struct CatalogShowRowLayout<Details: View, Control: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let artworkURL: URL?
    @ViewBuilder let details: Details
    @ViewBuilder let control: Control

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    artwork
                    details
                }
                control
            }
        } else {
            HStack(spacing: 12) {
                artwork
                details
                Spacer(minLength: 8)
                control
            }
        }
    }

    private var artwork: some View {
        ArtworkThumbnail(url: artworkURL)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One drawer row. It gets its follow state from the list's single pass instead of observing the
/// drawer, so a Follow tap re-renders only the row whose state changed (#246).
struct CatalogDrawerRow: View, Equatable {
    let entry: SourceCatalogEntry
    let state: CatalogDrawerModel.FollowState?
    let toggleFollow: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.state == rhs.state
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CatalogShowRowLayout(artworkURL: entry.artworkURL.flatMap(URL.init(string:))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
                }
            }
        } control: {
            followButton
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var followButton: some View {
        switch state {
        case .following:
            ProgressView().frame(minWidth: 96, minHeight: 44)
                .accessibilityLabel("Following \(entry.title)")
        case .followed:
            Label("Following", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.followed.\(entry.id)")
        case .failed:
            Button(action: toggleFollow) { Text("Retry").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle()) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry following \(entry.title)")
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        case nil:
            Button(action: toggleFollow) { Text("Follow").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle()) }
                .filledActionButton()
                .accessibilityLabel("Follow \(entry.title)")
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        }
    }
}

/// The drawer's search field, only when the app gave the drawer a search (#471). Clearing it returns to
/// the subject the listener was on, because the subject is never touched.
private struct DrawerSearchField: ViewModifier {
    @EnvironmentObject private var drawer: CatalogDrawerModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if drawer.supportsSearch {
            content.searchable(text: $drawer.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a podcast")
        } else {
            content
        }
    }
}

/// One search result. A show with no public feed has no Follow button; the row says why instead.
private struct CatalogSearchResultRow: View {
    let show: SourceCandidate
    let state: CatalogDrawerModel.FollowState?
    let toggleFollow: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        CatalogShowRowLayout(artworkURL: show.artworkURL.flatMap(URL.init(string:))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                if let author = show.author {
                    Text(author).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                }
                if show.feed == nil {
                    Text(show.reason).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(3)
                        .accessibilityIdentifier("catalog.search.unfollowable.\(show.id)")
                } else if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
                }
            }
        } control: {
            if show.feed != nil { followButton }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var followButton: some View {
        switch state {
        case .following:
            ProgressView().frame(minWidth: 96, minHeight: 44)
                .accessibilityLabel("Following \(show.title)")
        case .followed:
            Label("Following", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.search.followed.\(show.id)")
        case .failed:
            Button(action: toggleFollow) { Text("Retry").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle()) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry following \(show.title)")
                .accessibilityIdentifier("catalog.search.follow.\(show.id)")
        case nil:
            Button(action: toggleFollow) { Text("Follow").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle()) }
                .filledActionButton()
                .accessibilityLabel("Follow \(show.title)")
                .accessibilityIdentifier("catalog.search.follow.\(show.id)")
        }
    }
}

/// A subject chip in the podcast list: a 36 pt capsule inside a 44 pt hit area (#151).
struct CatalogSubjectChipLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            // The chip's selected trait says it; the glyph would read "checkmark" on top (#4639).
            if isSelected { Image(systemName: "checkmark").font(.caption.weight(.bold)).accessibilityHidden(true) }
            Text(title).font(.subheadline.weight(isSelected ? .semibold : .regular))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(isSelected ? AppColors.evergreen.opacity(0.16) : AppColors.panel, in: Capsule())
        .overlay { Capsule().stroke(isSelected ? AppColors.evergreen : AppColors.border) }
        .minimumTapTarget()
    }
}

extension FirstLaunchWelcomeOrder.Place {
    /// Where the first-run drawer's order (#3291) sees the listener: the Library only with no sheet or capture over it.
    @MainActor
    init(_ model: Gate1AppModel) {
        let covered = model.spokenMarginsPackageImportReview != nil || model.isTermsOfUsePresented || model.isHelpPresented
            || model.isSharingInterjectionsPresented || model.writtenMarginDraft != nil || model.snapshot.isRecording
            || model.packetOpenFailures.presented != nil
        if covered {
            self = .elsewhere
        } else if model.screen == .home {
            self = .library
        } else if model.screen == .item {
            self = .item
        } else {
            self = .elsewhere
        }
    }
}

/// The first-run drawer waits a moment for a file the system opened the app with, so a friend's file comes first
/// (#3291); after that it waits for the friend's item and then the Library. The root view notes the launch first.
private struct FirstLaunchWelcomeOrderModifier: ViewModifier {
    @ObservedObject var model: Gate1AppModel
    @ObservedObject var drawer: CatalogDrawerModel

    private var place: FirstLaunchWelcomeOrder.Place { FirstLaunchWelcomeOrder.Place(model) }

    func body(content: Content) -> some View {
        content
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                drawer.settleFirstRun(at: place)
            }
            .onChange(of: place) { _, place in drawer.listenerMoved(to: place) }
            .onChange(of: model.spokenMarginsPackageImportReview != nil) { _, arrived in
                if arrived { drawer.friendFileArrived() } // also files from the Share extension's inbox
            }
    }
}

extension View {
    /// Also hosts the sheet for a friend's link or file that failed to open, because closing it brings the drawer back (#3801).
    func firstLaunchWelcomeOrder(model: Gate1AppModel, drawer: CatalogDrawerModel) -> some View {
        modifier(FirstLaunchWelcomeOrderModifier(model: model, drawer: drawer))
            .packetOpenFailureSheet(model: model, drawer: drawer)
    }
}
