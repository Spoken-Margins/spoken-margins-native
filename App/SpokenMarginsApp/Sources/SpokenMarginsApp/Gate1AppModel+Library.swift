import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

enum NativeTextStartupAudioState: String, Hashable {
    case notRequired = "not_required"
    case preparing
    case ready
    case paused
    case failed
}

struct LibraryItemRow: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let canDelete: Bool
    var hasContinuationSession: Bool
    var continuationProgressPercent: Int?
    let isCompleted: Bool
    let mediaType: String
    let hasNativeAudio: Bool
    let sourceTitle: String?
    let sourceURL: String?
    let author: String?
    let sourceReference: String?
    let sourceReferenceType: String?
    var offlineState: LibraryOfflineStateFilter
    var startupAudioState: NativeTextStartupAudioState
    var startupAudioCompletedChunkCount: Int
    var startupAudioTargetChunkCount: Int
    let addedAt: Date?
    let lastListenedAt: Date?
    let storageRecencyRank: Int
    /// A PDF read through the structured-document reader (#359).
    var usesNewReader = false
    /// Marked complete by hand, not finished by listening, so Mark Unfinished can clear it (#273).
    var canMarkUnfinished = false

    var mediaSymbol: String {
        if hasNativeAudio { return "headphones" }
        return switch mediaType.lowercased() {
        case "podcast", "audio", "audiobook", "m4a", "m4b", "mp3":
            "headphones"
        case "pdf":
            "doc.richtext"
        case "epub":
            "book.closed"
        default:
            "doc.text"
        }
    }

    init(
        id: String,
        title: String,
        status: String,
        canDelete: Bool,
        hasContinuationSession: Bool = false,
        continuationProgressPercent: Int? = nil,
        isCompleted: Bool = false,
        mediaType: String = "text",
        hasNativeAudio: Bool = false,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        author: String? = nil,
        sourceReference: String? = nil,
        sourceReferenceType: String? = nil,
        offlineState: LibraryOfflineStateFilter = .onlineOnly,
        startupAudioState: NativeTextStartupAudioState = .notRequired,
        startupAudioCompletedChunkCount: Int = 0,
        startupAudioTargetChunkCount: Int = 0,
        addedAt: Date? = nil,
        lastListenedAt: Date? = nil,
        storageRecencyRank: Int = .max
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.canDelete = canDelete
        self.hasContinuationSession = hasContinuationSession
        self.continuationProgressPercent = continuationProgressPercent
        self.isCompleted = isCompleted
        self.hasNativeAudio = hasNativeAudio
        self.mediaType = mediaType
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.author = author
        self.sourceReference = sourceReference
        self.sourceReferenceType = sourceReferenceType
        self.offlineState = offlineState
        self.startupAudioState = startupAudioState
        self.startupAudioCompletedChunkCount = max(0, startupAudioCompletedChunkCount)
        self.startupAudioTargetChunkCount = max(0, startupAudioTargetChunkCount)
        self.addedAt = addedAt
        self.lastListenedAt = lastListenedAt
        self.storageRecencyRank = storageRecencyRank
    }
}

struct AudioPreparationQueueRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let policy: PreparationJobPolicy
    let state: PreparedAudioState
    let completedChunkCount: Int
    let plannedChunkCount: Int
    let requestedAt: Date
    let updatedAt: Date
    let failureCode: String?
    let isActivePlaybackItem: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    var progress: Double {
        guard plannedChunkCount > 0 else { return 0 }
        return min(1, Double(completedChunkCount) / Double(plannedChunkCount))
    }
}

struct RecentlyPreparedAudioRow: Identifiable, Hashable {
    let id: String
    let itemId: String
    let title: String
    let completedAt: Date
    let durationMs: Int
}

struct TrashUndoState: Identifiable, Equatable {
    let id = UUID()
    let itemId: String
    let title: String
}


struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    var overview = ""
    var navigation: [CanonicalNavigationNode] = []
    var chapters: [Chapter] = []
    var mediaChapters: [MediaTimelineChapter] = []
    var listeningMapScenes: [MediaTimelineChapter] = []
    var mediaDurationMs: Int?
    var isNativeAudio = false
    var documentStructure: PDFDocumentStructure?
    var sessions: [Session] = []
    var sessionRows: [SessionPresentation] = []
    var interjections: [Interjection] = []
    var importedCommentaryLayers: [ImportedCommentaryLayer] = []
    var importedCommentaryInterjections: [String: [ImportedCommentaryInterjection]] = [:]
    var turns: [ConversationTurn] = []
}

struct SessionPresentation: Identifiable {
    let session: Session
    let interjectionCount: Int
    let interjectionPreview: String?

    var id: String { session.id }
}


struct UITestingAmbiguousSourceLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .needsReview,
            originalLink: SourceLink(url: request.inputURL, provider: "spotify", role: "discovery"),
            candidates: [
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-one",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode One",
                    showTitle: "UI Test Show",
                    durationMs: 1_800_000,
                    publishedAt: "2026-08-01T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-one.mp3",
                    confidence: 0.71
                ),
                LinkResolutionCandidate(
                    sourceLink: SourceLink(
                        url: "https://podcasts.apple.com/ui-test/episode-two",
                        provider: "apple_podcasts",
                        role: "canonical_source"
                    ),
                    title: "Ambiguous Episode Two",
                    showTitle: "UI Test Show",
                    durationMs: 2_400_000,
                    publishedAt: "2026-08-02T00:00:00Z",
                    audioURL: "https://cdn.example.com/ui-test-episode-two.mp3",
                    confidence: 0.70
                )
            ],
            failureReason: "spotify_episode_match_ambiguous"
        )
    }
}

struct LibraryReadSnapshot: Sendable {
    let items: [Item]
    let sessions: [Session]
    let manifests: [PreparedAudioManifest]
    let jobs: [AudioPreparationJob]
    let downloads: [PodcastDownloadRecord]
    var structuredDocumentItemIds: Set<String> = []

    static func read(store: SQLiteSessionStore) throws -> Self {
        try Self(items: store.listItems(includeDeleted: true), sessions: store.loadSessions(),
                 manifests: store.loadPreparedAudioManifests(), jobs: store.loadAudioPreparationJobs(),
                 downloads: store.loadPodcastDownloads(), structuredDocumentItemIds: store.loadStructuredDocumentItemIds())
    }
}

extension Gate1AppModel {
    #if DEBUG
    /// Tests that model a write through the app must share its serialized connection.
    /// Opening another connection also races unrelated offline-ledger startup work.
    func libraryStoreForTesting() throws -> SQLiteSessionStore {
        precondition(Self.isRunningUnitTests)
        return try requireStore()
    }
    #endif

    func bootstrapLibraryIfNeeded() {
        guard libraryItems.isEmpty, store == nil else { return }
        do {
            let store = try requireStore()
            libraryAccessError = nil
            purgeExpiredEpisodeMapPreparationJobs(store: store)
            if let fixtureText = ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"],
               CommandLine.arguments.contains("--ui-testing") {
                try resetAndSeedUITestingText(
                    store: store,
                    title: ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] ?? "UI Test Text",
                    text: fixtureText,
                    reference: ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] ?? "ui-test"
                )
                return
            }
            if CommandLine.arguments.contains("--ui-testing") {
                resetAndSeed()
                return
            }
            var rows = try loadLibraryRows(store: store)
            libraryWasEmptyAtLaunch = rows.isEmpty
            let storedWelcomeSampleVersion = UserDefaults.standard.integer(
                forKey: Self.welcomeSampleSeedVersionKey
            )
            if Self.shouldSeedWelcomeSample(
                libraryIsEmpty: rows.isEmpty,
                storedVersion: storedWelcomeSampleVersion,
                isUITesting: CommandLine.arguments.contains("--ui-testing")
            ) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                rows = try loadLibraryRows(store: store)
                diagnostics["welcomeSample"] = "seeded:v\(Self.welcomeSampleSeedVersion)"
            }
            if !CommandLine.arguments.contains("--ui-testing"),
               !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
               UserDefaults.standard.integer(forKey: Self.guidedOnboardingSeedVersionKey) < 1,
               !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                rows = try loadLibraryRows(store: store)
                diagnostics["guidedOnboardingItem"] = "bundled_fallback_seeded"
            }
            if !CommandLine.arguments.contains("--ui-testing"),
               storedWelcomeSampleVersion < Self.welcomeSampleSeedVersion {
                UserDefaults.standard.set(
                    Self.welcomeSampleSeedVersion,
                    forKey: Self.welcomeSampleSeedVersionKey
                )
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            // Installing the Supertonic client establishes the current render
            // signature. Re-project rows so startup readiness never reuses a
            // manifest from an obsolete voice or model identity.
            rows = try loadLibraryRows(store: store)
            try reconcileOnboardingEvidence(store: store)
            try recoverInterruptedAIJobs(store: store, rows: rows)
            libraryItems = rows
            recentlyDeletedItems = try loadDeletedLibraryRows(store: store)
            let availableItemIDs = Set(rows.map(\.id))
            if let restoredSession = try store.loadSessions().first(where: {
                Self.isResumableSession($0) && availableItemIDs.contains($0.itemId)
            }), let engine {
                activeItemId = restoredSession.itemId
                snapshot = try engine.inspectSession(sessionId: restoredSession.id)
                try prepareSourceMediaPlayback(itemId: restoredSession.itemId)
                selectedItem = try loadItemDetail(id: restoredSession.itemId, store: store)
                diagnostics["restoredSession"] = restoredSession.id
                diagnostics["restoredSessionMode"] = "paused_without_autoplay"
            } else if let first = rows.first {
                activeItemId = first.id
                selectedItem = try loadItemDetail(id: first.id, store: store)
            } else {
                selectedItem = ItemDetailState()
            }
            refreshMarginRows()
            tryRefreshOfflineStorageUsage()
            diagnostics["libraryBootstrap"] = "loaded:\(rows.count)"
            reportSuccess(rows.isEmpty ? "Add a source to begin." : "Library ready.")
            try refreshAudioPreparationPresentation(store: store, announceNewCompletions: true)
            scheduleAutomaticAudioPreparationIfNeeded()
            // Recover missing opening windows as well as durable jobs. Yield
            // between items so a populated Library remains interactive.
            let startupCandidates = Self.startupPreparationCandidates(rows)
            Task { @MainActor [weak self] in
                for itemId in startupCandidates {
                    guard !Task.isCancelled, let self else { return }
                    self.scheduleStartupAudioPreparationIfNeeded(itemId: itemId)
                    await Task.yield()
                }
            }
            startForegroundAudioPreparationIfNeeded()
        } catch {
            libraryAccessError = "This build could not open your existing library. This attempt did not reset it. Do not use Reset Library or delete the app; install a compatible build and try again. Details: \(error.localizedDescription)"
            diagnostics["libraryBootstrap"] = "failed_without_reset:\(error.localizedDescription)"
            reportFailure(error, context: "Library bootstrap failed")
        }
    }

    private func resetAndSeedUITestingText(
        store: SQLiteSessionStore,
        title: String,
        text: String,
        reference: String
    ) throws {
        try store.reset()
        let item = Item(
            id: "item-ui-text-regression",
            title: title,
            mediaType: "text",
            text: text,
            externalReference: reference,
            status: "needs_listening_map"
        )
        try store.seed(item: item)
        self.store = store
        try configurePodcastDownloads(store: store)
        installEngine(try makeEngine(store: store))
        activeItemId = item.id
        liveSpeechFallbackItemIds.insert(item.id)
        snapshot = SessionSnapshot()
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = []
        completionUndo = nil
        dismissTrashUndo()
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics = [
            "runtimeProfile": selectedProfileId,
            "uiTestFixture": item.id,
            "speechRate": String(format: "%.2f", speechRate)
        ]
        reportSuccess("Loaded simulator speech regression article.")
    }

    func resetAndSeed() {
        do {
            if Self.isRunningUnitTests, databaseURLOverride == nil {
                databaseURLOverride = FileManager.default.temporaryDirectory
                    .appending(path: "spoken-margins-tests-\(UUID().uuidString).sqlite")
            }
            let databaseURL = try databaseURL()
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.reset()
            let item = try loadFixtureItem(name: "text-with-listening-map")
            let map = try loadFixtureMap(name: "valid-listening-map")
            try store.seed(item: item)
            try store.seed(map: map)
            self.store = store
            try configurePodcastDownloads(store: store)
            installEngine(try makeEngine(store: store))
            activeItemId = item.id
            snapshot = SessionSnapshot()
            libraryItems = try loadLibraryRows(store: store)
            recentlyDeletedItems = []
            completionUndo = nil
            dismissTrashUndo()
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics = [
                "runtimeProfile": selectedProfileId,
                "seededItems": "1",
                "database": databaseURL.lastPathComponent
            ]
            exportPreview = ""
            refreshMarginRows()
            tryRefreshOfflineStorageUsage()
            reportSuccess("Listening queue ready.")
        } catch {
            reportFailure(error, context: "Reset and seed failed")
        }
    }

    func openHome() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_home") else { return }
        screen = .home
        // Reflect the known source position without loading every saved item.
        if let index = libraryItems.firstIndex(where: { $0.id == snapshot.itemId }), snapshot.sessionId != nil {
            libraryItems[index].hasContinuationSession = true
            libraryItems[index].continuationProgressPercent = snapshot.sourceProgressPercent
        }
        navigationRefreshTask?.cancel()
        guard let store else { return }
        let revision = libraryPresentationRevision
        let read = navigationLibraryRead
        navigationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let data = try await read(store)
                try Task.checkCancellation()
                guard let self, self.screen == .home,
                      self.libraryPresentationRevision == revision else { return }
                let rows = self.libraryRows(from: data)
                if self.libraryItems != rows { self.libraryItems = rows }
                self.recentlyDeletedItems = data.items.filter { $0.deletedAt != nil }
                    .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }.map {
                    LibraryItemRow(id: $0.id, title: $0.title, status: "Recently deleted", canDelete: true)
                }
            } catch is CancellationError {
            } catch {
                self?.diagnostics["homeLibraryRefreshError"] = String(describing: error)
            }
        }
    }

    func openLibrary() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_library") else { return }
        openHome()
        requestedExperienceRoot = .library
    }

    var visibleLibraryItems: [LibraryItemRow] {
        let normalizedQuery = libraryQuery.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = libraryItems.filter { row in
            let metadataMatch: Bool
            if normalizedQuery.isEmpty {
                metadataMatch = true
            } else {
                metadataMatch = [row.title, row.sourceTitle, row.author]
                    .compactMap { $0 }
                    .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
                    .contains { $0.localizedStandardContains(normalizedQuery) }
            }
            let contentMatch = libraryQuery.contentType == .all || libraryContentType(for: row) == libraryQuery.contentType
            let listeningMatch: Bool
            switch libraryQuery.listeningState {
            case .all: listeningMatch = true
            case .unfinished: listeningMatch = !row.isCompleted
            case .unplayed: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) == 0
            case .inProgress: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) > 0
            case .completed: listeningMatch = row.isCompleted
            }
            let offlineMatch = libraryQuery.offlineState == .all || row.offlineState == libraryQuery.offlineState
            return metadataMatch && contentMatch && listeningMatch && offlineMatch
        }
        return filtered.sorted { lhs, rhs in
            let ordered: ComparisonResult
            switch libraryQuery.sort {
            case .recentlyAdded:
                if lhs.addedAt != nil, rhs.addedAt != nil {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                } else if lhs.storageRecencyRank != rhs.storageRecencyRank {
                    ordered = lhs.storageRecencyRank < rhs.storageRecencyRank ? .orderedAscending : .orderedDescending
                } else {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                }
            case .recentlyListened:
                ordered = compareDates(lhs.lastListenedAt, rhs.lastListenedAt)
            case .title:
                ordered = lhs.title.localizedStandardCompare(rhs.title)
            case .progress:
                let left = lhs.continuationProgressPercent ?? 0
                let right = rhs.continuationProgressPercent ?? 0
                ordered = left == right ? .orderedSame : (left > right ? .orderedAscending : .orderedDescending)
            }
            return ordered == .orderedSame ? lhs.id < rhs.id : ordered == .orderedAscending
        }
    }

    static func loadLibraryListeningFilter(defaults: UserDefaults) -> LibraryListeningStateFilter {
        let key = "libraryListeningStateFilter"
        let saved = LibraryListeningStateFilter(rawValue: defaults.string(forKey: key) ?? "")
        if !defaults.bool(forKey: "libraryUnfinishedDefaultApplied") {
            let selection = saved == nil || saved == .all ? LibraryListeningStateFilter.unfinished : saved!
            defaults.set(selection.rawValue, forKey: key)
            defaults.set(true, forKey: "libraryUnfinishedDefaultApplied")
            return selection
        }
        return saved ?? .unfinished
    }

    var libraryIsCaughtUp: Bool {
        !libraryItems.isEmpty && libraryItems.allSatisfy(\.isCompleted)
            && libraryQuery.listeningState == .unfinished
            && libraryQuery.contentType == .all && libraryQuery.offlineState == .all
            && libraryQuery.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var libraryHidesCompleted: Bool {
        [.unfinished, .unplayed, .inProgress].contains(libraryQuery.listeningState)
    }

    func showCompletedLibraryItems() {
        libraryQuery.listeningState = .completed
        libraryQueryChanged()
    }

    func resetLibraryFilters() {
        // Preserve the search and sort while restoring the everyday view.
        libraryQuery.contentType = .all
        libraryQuery.listeningState = .unfinished
        libraryQuery.offlineState = .all
        libraryQueryChanged()
    }

    func libraryQueryChanged() {
        let persisted = libraryQuery.persistedSelection
        UserDefaults.standard.set(persisted.contentType.rawValue, forKey: "libraryContentTypeFilter")
        UserDefaults.standard.set(persisted.listeningState.rawValue, forKey: "libraryListeningStateFilter")
        UserDefaults.standard.set(persisted.offlineState.rawValue, forKey: "libraryOfflineStateFilter")
        UserDefaults.standard.set(persisted.sort.rawValue, forKey: "librarySort")
    }

    var libraryFilterDescription: String {
        var selections: [String] = []
        if libraryQuery.contentType != .all {
            selections.append(Self.displayName(libraryQuery.contentType.rawValue))
        }
        if libraryQuery.listeningState != .all {
            selections.append(Self.displayName(libraryQuery.listeningState.rawValue))
        }
        if libraryQuery.offlineState != .all {
            selections.append(Self.displayName(libraryQuery.offlineState.rawValue))
        }
        return selections.isEmpty ? "All items" : selections.joined(separator: " · ")
    }

    var librarySortDescription: String {
        Self.displayName(libraryQuery.sort.rawValue)
    }

    nonisolated static func displayName(_ rawValue: String) -> String {
        switch rawValue {
        case "pdf": return "PDF"
        case "epub": return "EPUB"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func libraryContentType(for row: LibraryItemRow) -> LibraryContentTypeFilter {
        LibraryRowWording.contentType(mediaType: row.mediaType, sourceReference: row.sourceReference, sourceReferenceType: row.sourceReferenceType)
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left > right ? .orderedAscending : .orderedDescending
    }

    func openOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_offline_storage") else { return }
        tryRefreshOfflineStorageUsage()
        screen = .offlineStorage
    }

    func refreshOfflineStoragePresentation() {
        tryRefreshOfflineStorageUsage()
    }

    func returnToSettingsFromOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("return_to_settings") else { return }
        screen = .settings
    }

    func openItem(id: String) {
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        defer { recordDeveloperDiagnostic("item.open.end", ["durationMs": String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStart) * 1000))]) }
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            prepareImportedLocalAudioBridges(itemId: id)
            scheduleTextAudioPrewarmIfNeeded(itemId: id)
            listeningMapJSON = ""
            screen = .item
            discoverFollowOfferIfEligible(itemId: id, store: store)
            offerFollowSuggestionIfEligible(itemId: id, store: store)
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    func markItemCompleted(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_completed") else { return }
        do {
            let store = try requireStore()
            // Completion is an item-level fact, not fabricated listening history.
            guard let item = try ManualItemCompletion.markComplete(itemId: id, in: store) else { return }
            try refreshLibraryRows(store: store)
            if selectedItem.id == id { selectedItem = try loadItemDetail(id: id, store: store) }
            completionUndo = (id, item.title, item.sourceCompletedAt ?? Date())
            let completion = completionUndo
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.completionUndo?.itemID == completion?.itemID,
                      self.completionUndo?.markedAt == completion?.markedAt else { return }
                self.completionUndo = nil
            }
        } catch {
            reportFailure(error, context: "Mark complete failed")
        }
    }

    func undoMarkedCompletion() {
        guard let undo = completionUndo else { return }
        clearMarkedCompletion(id: undo.itemID, markedAt: undo.markedAt)
    }

    /// Any time after the undo banner is gone (#273). Only a completion set by hand.
    func markItemUnfinished(id: String) { clearMarkedCompletion(id: id, markedAt: nil) }

    private func clearMarkedCompletion(id: String, markedAt: Date?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("mark_item_unfinished") else { return }
        if completionUndo?.itemID == id { completionUndo = nil }
        do {
            let store = try requireStore()
            // Never a later completion, and never natural session completion.
            guard let item = try ManualItemCompletion.markUnfinished(itemId: id, markedAt: markedAt, in: store) else { return }
            try refreshLibraryRows(store: store)
            if selectedItem.id == id { selectedItem = try loadItemDetail(id: id, store: store) }
            reportConfirmation(markedAt == nil ? "Marked \(item.title) unfinished." : "Undid Mark Complete for \(item.title).")
        } catch { reportFailure(error, context: "Mark unfinished failed") }
    }

    func prioritizeOfflinePreparation(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if libraryItems.first(where: { $0.id == id })?.offlineState == .readyOffline {
                reportConfirmation("\(item.title) is already available offline.")
                return
            }

            switch item.media?.sourceType {
            case .some(.nativeMediaFile):
                reportConfirmation("\(item.title) is already available offline.")
            case .some(.remoteStream):
                guard let rawURL = item.media?.url, let remoteURL = URL(string: rawURL) else {
                    reportFailure("This audio item does not have a downloadable source.")
                    return
                }
                if podcastDownloadCoordinator?.downloadNow(itemId: id) != true {
                    podcastDownloadCoordinator?.register(itemId: id, remoteURL: remoteURL, userInitiated: true)
                }
                reportConfirmation("Prioritized \(item.title) for download.")
            case .some(.browserOwnedMedia):
                reportFailure("Browser-owned audio cannot be downloaded by Spoken Margins.")
            case .none, .some(.generatedTTSRealtime), .some(.generatedTTSPrerendered):
                guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    reportFailure("This item does not have text that can be prepared for offline listening.")
                    return
                }
                guard hasAcceptedCurrentTerms, ttsVoiceSelection.supertonicVoice != nil else {
                    reportWarning("Choose a bundled voice and accept its terms before preparing this item offline.")
                    return
                }
                Task { [weak self] in
                    await self?.enqueueExplicitAudioPreparation(item: item)
                }
            }
        } catch {
            reportFailure(error, context: "Offline preparation failed", itemId: id)
        }
    }

    func deleteItem(id: String) {
        moveItemToTrash(id: id)
    }

    func moveItemToTrash(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("move_item_to_trash") else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            if id == Self.guidedOnboardingItemId {
                UserDefaults.standard.set(true, forKey: Self.guidedOnboardingTombstoneKey)
            }
            if snapshot.itemId == id {
                _ = try? engine?.stopPlayback()
            }
            try store.moveItemToTrash(id: id)
            try refreshLibraryRows(store: store)
            if activeItemId == id {
                activeItemId = libraryItems.first?.id ?? "item-pill"
                snapshot = SessionSnapshot()
                exportPreview = ""
                selectedItem = libraryItems.first.map { (try? loadItemDetail(id: $0.id, store: store)) ?? ItemDetailState() } ?? ItemDetailState()
            }
            screen = .home
            presentTrashUndo(itemId: id, title: item.title)
            reportSuccess("Moved \(item.title) to Recently Deleted.")
        } catch {
            reportFailure(error, context: "Move to Recently Deleted failed")
        }
    }

    func undoLastTrash() {
        guard let trashUndo else { return }
        restoreItem(id: trashUndo.itemId)
    }

    func dismissTrashUndo() {
        dismissTrashUndo(id: nil)
    }

    private func presentTrashUndo(itemId: String, title: String) {
        trashUndoDismissTask?.cancel()
        let undo = TrashUndoState(itemId: itemId, title: title)
        trashUndo = undo
        trashUndoDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: trashUndoDismissDelay)
                dismissTrashUndo(id: undo.id)
            } catch {
                // Manual dismissal, Undo, replacement, and teardown cancel this timer.
            }
        }
    }

    private func dismissTrashUndo(id: UUID?) {
        guard id == nil || trashUndo?.id == id else { return }
        trashUndoDismissTask?.cancel()
        trashUndoDismissTask = nil
        trashUndo = nil
    }

    func restoreItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            try store.restoreItem(id: id)
            try refreshLibraryRows(store: store)
            dismissTrashUndo()
            reportSuccess("Restored \(item.title).")
        } catch {
            reportFailure(error, context: "Restore failed")
        }
    }

    func permanentlyDeleteItem(id: String) {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: id)
            guard item.deletedAt != nil else {
                reportFailure("Move the item to Recently Deleted before deleting it permanently.")
                return
            }
            podcastDownloadCoordinator?.removeItem(id)
            removeDurableGeneratedAudio(for: item)
            removeEpisodeMapArtifacts(itemId: id)
            try store.deleteItem(id: id)
            try refreshLibraryRows(store: store)
            guard !libraryItems.contains(where: { $0.id == id }),
                  !recentlyDeletedItems.contains(where: { $0.id == id }),
                  (try? store.loadItem(id: id)) == nil,
                  (try? store.loadSessions(itemId: id))?.isEmpty != false else {
                throw SessionKitError.persistenceFailed("permanent_delete_verification_failed")
            }
            if trashUndo?.itemId == id {
                dismissTrashUndo()
            }
            reportSuccess("Permanently deleted \(item.title).")
        } catch {
            reportFailure(error, context: "Permanent delete failed")
        }
    }

    func permanentlyDeleteRecentlyDeletedItems() {
        do {
            let store = try requireStore()
            let ids = recentlyDeletedItems.map(\.id)
            guard !ids.isEmpty else {
                reportSuccess("Recently Deleted is already empty.")
                return
            }
            let items = try ids.map { try store.loadItem(id: $0) }
            for item in items {
                guard item.deletedAt != nil else {
                    throw SessionKitError.persistenceFailed("bulk_delete_requires_trashed_items")
                }
            }
            ids.forEach { podcastDownloadCoordinator?.removeItem($0) }
            items.forEach(removeDurableGeneratedAudio)
            ids.forEach(removeEpisodeMapArtifacts)
            try store.deleteItems(ids: ids)
            try refreshLibraryRows(store: store)
            guard recentlyDeletedItems.isEmpty,
                  ids.allSatisfy({ (try? store.loadItem(id: $0)) == nil }) else {
                throw SessionKitError.persistenceFailed("bulk_permanent_delete_verification_failed")
            }
            if let undoItemId = trashUndo?.itemId, ids.contains(undoItemId) {
                dismissTrashUndo()
            }
            reportSuccess("Permanently deleted \(ids.count) item\(ids.count == 1 ? "" : "s") from Recently Deleted.")
        } catch {
            reportFailure(error, context: "Empty Recently Deleted failed")
        }
    }

    var selectedItemStartupAudioState: NativeTextStartupAudioState {
        libraryItems.first(where: { $0.id == selectedItem.id })?.startupAudioState ?? .notRequired
    }

    var selectedItemStartupAudioProgressDescription: String {
        guard let row = libraryItems.first(where: { $0.id == selectedItem.id }),
              row.startupAudioTargetChunkCount > 0 else {
            return "Preparing opening audio"
        }
        return "Preparing opening audio · \(row.startupAudioCompletedChunkCount) of \(row.startupAudioTargetChunkCount) chunks"
    }

    func openReadyListeningEdition() {
        guard !snapshot.isRecording, let id = ListeningReadyNotifications.pendingItemID else { return }
        ListeningReadyNotifications.pendingItemID = nil
        openItem(id: id)
    }

    func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func shouldSkipTextAudioPreparation(_ sessions: [Session]) -> Bool {
        itemIsCompleted(sessions) || sessions.contains { session in
            session.completedAt != nil
                || session.status == "finished"
                || session.phase == .finished
                || session.completionPercent >= textAudioPreparationCutoffPercent
        }
    }

    nonisolated static func itemIsCompleted(_ sessions: [Session]) -> Bool {
        sessions.contains { session in
            session.completedAt != nil
                || session.status == "finished"
                || session.phase == .finished
                || session.completionPercent > 98
        }
    }

    func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        libraryRows(from: try LibraryReadSnapshot.read(store: store))
    }

    private func libraryRows(from data: LibraryReadSnapshot) -> [LibraryItemRow] {
        let items = data.items.filter { $0.deletedAt == nil }
        let sessionsByItemId = Dictionary(grouping: data.sessions, by: \.itemId)
        let manifestsByItemId = Dictionary(grouping: data.manifests, by: \.itemId)
        let preparationJobsByManifestId = Dictionary(
            grouping: data.jobs.filter { !$0.isCancelled },
            by: \.manifestId
        ).compactMapValues { jobs in
            jobs.max { $0.requestedAt < $1.requestedAt }
        }
        let podcastDownloadsByItemId = Dictionary(
            grouping: data.downloads,
            by: \.itemId
        ).compactMapValues { records in
            records.max { $0.updatedAt < $1.updatedAt }
        }
        return items.enumerated().map { storageRank, item in
            let sessions = sessionsByItemId[item.id] ?? []
            let continuation = Self.preferredContinuationSession(in: sessions)
            let isCompleted = item.sourceCompletedAt != nil || Self.itemIsCompleted(sessions)
            let compatibleManifests = manifestsByItemId[item.id]?.filter { manifest in
                currentSupertonicRenderSignature.map { manifest.signature == $0 } ?? true
            }
            let latestManifest = compatibleManifests?.max { $0.updatedAt < $1.updatedAt }
            let preparationJob = latestManifest.flatMap { preparationJobsByManifestId[$0.id] }
            let startupAudio: (state: NativeTextStartupAudioState, completed: Int, target: Int) = isCompleted ? (.notRequired, 0, 0) : libraryStartupAudioPresentation(
                item: item,
                manifest: latestManifest,
                job: preparationJob
            )
            let effectivePreparedState: PreparedAudioState? = {
                guard latestManifest?.state == .preparing, preparationJob == nil else {
                    return latestManifest?.state
                }
                return .notPrepared
            }()
            let offlineState = Self.libraryOfflineState(
                preparedState: effectivePreparedState,
                mediaSourceType: item.media?.sourceType,
                podcastDownloadState: podcastDownloadsByItemId[item.id]?.state
            )
            var row = LibraryItemRow(
                id: item.id,
                title: item.title,
                status: libraryStatusLabel(for: item),
                canDelete: true,
                hasContinuationSession: continuation != nil,
                continuationProgressPercent: continuation?.completionPercent,
                isCompleted: isCompleted,
                mediaType: item.mediaType,
                hasNativeAudio: item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream,
                sourceTitle: item.sourceTitle ?? item.externalReference,
                sourceURL: item.sourceURL,
                author: item.author,
                sourceReference: item.externalReference,
                sourceReferenceType: item.externalReferenceType,
                offlineState: offlineState,
                startupAudioState: startupAudio.state,
                startupAudioCompletedChunkCount: startupAudio.completed,
                startupAudioTargetChunkCount: startupAudio.target,
                addedAt: item.createdAt,
                lastListenedAt: sessions.compactMap { $0.updatedAt ?? $0.createdAt }.max(),
                storageRecencyRank: storageRank
            )
            row.usesNewReader = data.structuredDocumentItemIds.contains(item.id)
            row.canMarkUnfinished = item.sourceCompletedAt != nil && !Self.itemIsCompleted(sessions)
            return row
        }
    }

    func libraryStartupAudioPresentation(
        item: Item,
        manifest: PreparedAudioManifest?,
        job: AudioPreparationJob?
    ) -> (state: NativeTextStartupAudioState, completed: Int, target: Int) {
        guard hasAcceptedCurrentTerms,
              ttsVoiceSelection.supertonicVoice != nil,
              !suppressedAutomaticAudioPreparationItemIds.contains(item.id),
              !liveSpeechFallbackItemIds.contains(item.id),
              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return (.notRequired, 0, 0)
        }
        if item.media?.sourceType == .generatedTTSPrerendered,
           isPreparedTextMediaAvailable(item.media),
           !isStarterPreparedTextMedia(item.media) {
            return (.ready, Self.startupAudioChunkCount, Self.startupAudioChunkCount)
        }
        guard shouldPrewarmTextAudio(for: item) else { return (.notRequired, 0, 0) }
        guard let manifest else {
            return failedStartupAudioPreparationItemIds.contains(item.id)
                ? (.failed, 0, Self.startupAudioChunkCount)
                : (.preparing, 0, Self.startupAudioChunkCount)
        }
        let target = min(Self.startupAudioChunkCount, max(1, manifest.plannedChunkCount))
        let completed = min(target, manifest.chunks.filter { $0.index < target }.count)
        if manifest.state == .readyOffline || completed >= target {
            return (.ready, completed, target)
        }
        if failedStartupAudioPreparationItemIds.contains(item.id)
            || job?.lastFailureCode?.isEmpty == false
            || manifest.state == .failed
            || manifest.state == .needsRepreparation
            || manifest.state == .stopped {
            return (.failed, completed, target)
        }
        if !SupertonicResourcePolicy.allowsRendering()
            || manifest.state == .pausedForThermal {
            return (.paused, completed, target)
        }
        return (.preparing, completed, target)
    }

    nonisolated static func libraryOfflineState(
        preparedState: PreparedAudioState?,
        mediaSourceType: AudioSourceType?,
        podcastDownloadState: PodcastDownloadState?
    ) -> LibraryOfflineStateFilter {
        if let podcastDownloadState {
            switch podcastDownloadState {
            case .availableOffline: return .readyOffline
            case .downloading, .waitingForWiFi: return .preparing
            case .failed, .evicted: return .needsRepreparation
            case .streamingOnly: return .onlineOnly
            }
        }
        if let preparedState {
            switch preparedState {
            case .preparing, .pausedForThermal: return .preparing
            case .readyOffline: return .readyOffline
            case .needsRepreparation, .failed, .stopped: return .needsRepreparation
            case .notPrepared: return .onlineOnly
            }
        }
        return mediaSourceType == .nativeMediaFile ? .readyOffline : .onlineOnly
    }

    private func loadDeletedLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listDeletedItems().map { item in
            LibraryItemRow(id: item.id, title: item.title, status: "Recently deleted", canDelete: true)
        }
    }

    func refreshLibraryRows(store: SQLiteSessionStore) throws {
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = try loadDeletedLibraryRows(store: store)
        try refreshAudioPreparationPresentation(store: store)
    }

    private func recoverInterruptedAIJobs(store: SQLiteSessionStore, rows: [LibraryItemRow]) throws {
        var recovered = 0
        for row in rows {
            for session in try store.loadSessions(itemId: row.id) {
                for var job in try store.loadAIJobs(sessionId: session.id) where job.status == "pending" || job.status == "streaming" {
                    let remoteJobDisabled = !remoteProviderExperienceEnabled
                        && job.providerType != "apple_foundation_on_device"
                    job.status = remoteJobDisabled ? "failed" : "retryable"
                    job.lastError = remoteJobDisabled
                        ? "remote_provider_disabled_by_feature_flag"
                        : "app_terminated_during_stream"
                    try store.updateAIJob(job)
                    if let turnId = job.turnId,
                       var turn = try store.loadTurns(sessionId: session.id).first(where: { $0.id == turnId && $0.status == "streaming" }) {
                        turn.status = "failed_partial"
                        try store.saveTurn(turn)
                    }
                    recovered += 1
                }
            }
        }
        diagnostics["recoveredInterruptedAIJobs"] = "\(recovered)"
    }

    private func libraryStatusLabel(for item: Item) -> String {
        guard item.status == "ready" else {
            switch item.status {
            case "needs_listening_map": return "Ready to listen · map optional"
            case "in_progress": return "In progress"
            case "finished": return "Finished"
            case "map_needs_repair": return "Listening map needs attention"
            default: return item.status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        if item.media != nil || item.mediaType == TargetType.transcriptBackedMedia.rawValue {
            return "Audio ready"
        }
        return "Ready to listen"
    }

    private func isUserImportedItem(_ id: String) -> Bool {
        id.hasPrefix("item-import-") || id.hasPrefix("item-obsidian-") || id.hasPrefix("item-browser-") || id.hasPrefix("item-source-")
    }

    func refreshSelectedItem() {
        guard let store, !activeItemId.isEmpty else { return }
        if let detail = try? loadItemDetail(id: activeItemId, store: store) {
            selectedItem = detail
            selectedListeningEdition = try? ListeningEditionStore.application().load(itemID: activeItemId)
            offerFollowSuggestionIfEligible(itemId: activeItemId, store: store)
        }
    }

    func loadItemDetail(id: String, store: SQLiteSessionStore) throws -> ItemDetailState {
        let item = try store.loadItem(id: id)
        var map = try store.loadListeningMap(itemId: id)
        let canonicalSource = try store.loadCanonicalSource(itemId: id)
        if map == nil,
           let canonicalSource,
           let derivedMap = canonicalSource.derivedListeningMap() {
            try store.saveListeningMap(derivedMap)
            map = derivedMap
        }
        let mediaTimeline = try store.loadTranscriptTimeline(itemId: id)?.timeline
        let mediaChapters = mediaTimeline?.chapters ?? []
        let projection = try store.loadResolvedListeningMapProjection(itemId: id)
        let proposal = SharedListeningMapPlacement.proposal(
            for: projection, committed: try store.loadPortableListeningMapProposals(itemId: id),
            layers: try store.loadImportedCommentaryLayers(itemId: id))
        let exactIdentityProjection = projection?.algorithmVersion == "episode-projection.exact-edition.v1"
            || (projection?.points.isEmpty == false
                && projection?.points.allSatisfy {
                    ($0.confidence == .exactEdition || $0.confidence == .verified)
                        && $0.recipientMediaTimeMs == $0.sourceMediaTimeMs
                } == true)
        let listeningMapScenes = proposal?.scenes
            .sorted { $0.order < $1.order }
            .compactMap { scene -> MediaTimelineChapter? in
                guard let sourceStartMs = scene.startAnchor.mediaTimeMs,
                      let startMs = projection?.projectedRecipientTime(for: sourceStartMs)
                        ?? (exactIdentityProjection ? sourceStartMs : nil) else {
                    return nil
                }
                let title = scene.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \(scene.order + 1)"
                return MediaTimelineChapter(
                    id: scene.id,
                    title: displayTitle,
                    description: scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    startMs: startMs,
                    transcriptSegmentId: scene.startAnchor.transcriptSegmentId ?? scene.id
                )
            }.sorted { $0.startMs < $1.startMs } ?? []
        let sessions = try store.loadSessions(itemId: id)
        // A snapshot session is valid only for its own item. Without this
        // ownership check, an asynchronous selection bug can display one
        // item's title with another item's interjections and turns.
        let snapshotSessionId = snapshot.itemId == id ? snapshot.sessionId : nil
        let activeSessionId = snapshotSessionId.flatMap { candidate in
            sessions.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? sessions.first?.id
        let storedInterjections = activeSessionId.flatMap {
            try? store.loadInterjections(sessionId: $0).filter { $0.status == "active" }
        } ?? []
        let isNativeAudio = item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream
        let interjections = storedInterjections.map { interjection -> Interjection in
            guard isNativeAudio,
                  interjection.targetType == .item,
                  let mediaTimeMs = interjection.anchor.mediaTimeMs,
                  let mediaTimeline else {
                return interjection
            }
            var resolved = interjection
            if let context = SourceAnchorContextResolver.resolve(
                mediaTimeMs: mediaTimeMs,
                timeline: mediaTimeline
            ) {
                resolved.anchor.anchorBefore = context.anchorBefore
                resolved.anchor.anchorAfter = context.anchorAfter
                resolved.anchor.transcriptSegmentId = context.transcriptSegmentId
                resolved.anchor.startChar = context.startChar
                resolved.anchor.endChar = context.endChar
                resolved.anchorContextStatus = .ready
            } else {
                resolved.anchor.anchorBefore = ""
                resolved.anchor.anchorAfter = ""
                resolved.anchor.transcriptSegmentId = nil
                resolved.anchor.startChar = 0
                resolved.anchor.endChar = 0
                resolved.anchorContextStatus = .unavailable
            }
            return resolved
        }
        let activeInterjectionIDs = Set(storedInterjections.map(\.id))
        let turns = (activeSessionId.flatMap { try? store.loadTurns(sessionId: $0) } ?? []).filter { turn in
            guard turn.turnType == "interjection_summary", !turn.sourceInterjectionIds.isEmpty else {
                return true
            }
            return Set(turn.sourceInterjectionIds).isSubset(of: activeInterjectionIDs)
        }
        let sessionRows = sessions.map { session in
            let notes = ((try? store.loadInterjections(sessionId: session.id)) ?? [])
                .filter { $0.status == "active" }
            return SessionPresentation(
                session: session,
                interjectionCount: notes.count,
                interjectionPreview: notes.reversed().compactMap { note in
                    let text = note.cleanedTranscript ?? note.transcript ?? note.displayText
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
                }.first
            )
        }
        let importedLayers = try store.loadImportedCommentaryLayers(itemId: id)
            .filter { $0.deletedAt == nil }
        let importedInterjections = Dictionary(uniqueKeysWithValues: importedLayers.map { layer in
            (layer.id, (try? store.loadImportedCommentaryInterjections(layerId: layer.id)) ?? [])
        })
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            overview: map?.overview ?? "",
            navigation: canonicalSource?.navigation ?? [],
            chapters: map?.chapters ?? [],
            mediaChapters: mediaChapters,
            listeningMapScenes: listeningMapScenes,
            mediaDurationMs: item.media?.durationMs ?? mediaTimeline?.durationMs,
            isNativeAudio: isNativeAudio,
            documentStructure: item.documentStructure,
            sessions: sessions,
            sessionRows: sessionRows,
            interjections: interjections,
            importedCommentaryLayers: importedLayers,
            importedCommentaryInterjections: importedInterjections,
            turns: turns
        )
    }

    func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let url = try databaseURL()
        if let backupURL = try archiveLegacyLibraryIfNeeded(at: url) {
            legacyLibraryResetNotice = "This beta starts with a fresh library. Your earlier test database was archived at \(backupURL.lastPathComponent)."
            diagnostics["legacyLibraryArchive"] = backupURL.path
        }
        let store = try SQLiteSessionStore(path: url.path)
        self.store = store
        try configurePodcastDownloads(store: store)
        return store
    }

    func configureOfflineServices(store: SQLiteSessionStore) throws {
        let support = try applicationSupportDirectory()
        let ledger = OfflineStorageLedger(repository: store, rootDirectory: support)
        offlineStorageLedger = ledger
        localSourceImporter = LocalSourceImporter(
            repository: store,
            ledger: ledger,
            applicationSupportDirectory: support
        )
        followedSourceCoordinator = FollowedSourceCoordinator(repository: store)
        guidedOnboardingCoordinator = GuidedOnboardingCoordinator(
            directory: support.appending(path: "GuidedOnboarding", directoryHint: .isDirectory),
            ledger: ledger
        )
        Task {
            try? store.saveOfflineStorageBudget(OfflineStorageBudget(
                limitBytes: Int64(self.offlineStorageLimitGB) * OfflineStorageBudget.bytesPerGigabyte
            ))
            try? await ledger.adoptExistingAssets()
            let residualOverage = try? await ledger.enforceBudget()
            let reconciled = await ledger.lastReconciliation?.summary ?? "failed"
            let ledgerBytes = try? await ledger.inventoryBytes()
            let filesystemBytes = await ledger.directFilesystemBytes()
            await MainActor.run { [weak self] in
                self?.diagnostics["offlineLedgerReconciled"] = reconciled
                self?.diagnostics["offlineLedgerBytes"] = "\(ledgerBytes ?? 0)"
                self?.diagnostics["offlineFilesystemBytes"] = "\(filesystemBytes)"
                self?.diagnostics["offlineResidualOverageBytes"] = "\(residualOverage ?? 0)"
                self?.tryRefreshOfflineStorageUsage()
            }
            await self.refreshFollowedSources(force: false)
            await self.refreshGuidedOnboardingContent()
        }
    }

    private func archiveLegacyLibraryIfNeeded(at databaseURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path),
              SQLiteSessionStore.schemaVersion(atPath: databaseURL.path) == 1 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archiveDirectory = databaseURL
            .deletingLastPathComponent()
            .appending(path: "LegacyLibraryBackup")
            .appending(path: formatter.string(from: Date()))
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(
                at: source,
                to: archiveDirectory.appending(path: source.lastPathComponent)
            )
        }
        return archiveDirectory
    }

    private func databaseURL() throws -> URL {
        if let databaseURLOverride {
            return databaseURLOverride
        }
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "SpokenMarginsGate1.sqlite")
    }
}
