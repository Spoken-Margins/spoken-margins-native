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

/// Library bootstrap and launch seeding (#1020).
extension Gate1AppModel {
    /// Try again on the "this version can't open your Library" note (#1969). A half-finished open can leave a store
    /// behind that the bootstrap guard would trust, so this forgets it and opens again. Nothing is reset or deleted.
    func retryLibraryOpen() {
        guard libraryAccessError != nil else { return }
        store = nil
        bootstrapLibraryIfNeeded()
    }

    func bootstrapLibraryIfNeeded() {
        guard pendingUITestingSeed != nil || (libraryItems.isEmpty && store == nil) else { return }
        SessionShareFiles.removeLeftovers() // files of a multi-session share whose sheet died with the app (#1528)
        do {
            let store = try requireStore()
            libraryAccessError = nil
            purgeExpiredEpisodeMapPreparationJobs(store: store)
            let seed = pendingUITestingSeed ?? UITestingLaunchSeed.none; pendingUITestingSeed = nil
            switch seed {
            case .none: break
            case .keepLibrary: try UITestingLaunchSeedWriter.importCoopLayerIfRequested(into: store)
            case .firstRun: try store.reset() // then the launch goes on as a new install's does
            case .fixture: resetAndSeed(); return
            case .importedPDF: resetAndSeed(); try importObsidianMarkdownFiles(urls: [UITestingLaunchSeedWriter.writePDF()]); return
            case .text, .offlinePodcast:
                try seedUITesting(store: store, item: UITestingLaunchSeedWriter.write(seed, into: store)); return
            }
            var rows = try loadLibraryRows(store: store)
            libraryWasEmptyAtLaunch = rows.isEmpty
            let storedWelcomeSampleVersion = UserDefaults.standard.integer(
                forKey: Self.welcomeSampleSeedVersionKey
            )
            if Self.shouldSeedWelcomeSample(
                libraryIsEmpty: rows.isEmpty,
                storedVersion: storedWelcomeSampleVersion,
                isUITesting: UITestingHooks.suppressesFirstRun
            ) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                rows = try loadLibraryRows(store: store)
                diagnostics["welcomeSample"] = "seeded:v\(Self.welcomeSampleSeedVersion)"
            }
            if !UITestingHooks.suppressesFirstRun,
               !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
               UserDefaults.standard.integer(forKey: Self.guidedOnboardingSeedVersionKey) < 1,
               !(try store.hasLiveItem(id: Self.guidedOnboardingItemId)) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                rows = try loadLibraryRows(store: store)
                diagnostics["guidedOnboardingItem"] = "bundled_fallback_seeded"
            }
            if !UITestingHooks.suppressesFirstRun,
               storedWelcomeSampleVersion < Self.welcomeSampleSeedVersion {
                UserDefaults.standard.set(
                    Self.welcomeSampleSeedVersion,
                    forKey: Self.welcomeSampleSeedVersionKey
                )
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            let recordingDraftNotice = reconcileRecordingDrafts(store: store)
            // Installing the Supertonic client establishes the current render
            // signature. Re-project rows so startup readiness never reuses a
            // manifest from an obsolete voice or model identity.
            // The Recently Deleted rows come from this same read: the snapshot already holds deleted items, so a
            // second `listDeletedItemSummaries` pass would read the whole item table again (#2508).
            let launchData = try LibraryReadSnapshot.read(store: store)
            rows = LibraryRowBuilder.rows(from: launchData, context: startupAudioContext)
            let deletedRows = Self.recentlyDeletedRows(from: launchData)
            try reconcileOnboardingEvidence(items: launchData.liveItems, store: store)
            try recoverInterruptedAIJobs(store: store, rows: rows); settleOrphanedTranscriptions(store: store)
            libraryItems = rows
            recentlyDeletedItems = deletedRows
            let availableItemIDs = Set(rows.map(\.id))
            var writtenMarginNotice: String?
            if let restoredSession = launchData.sessions.first(where: {
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
            settleReviewPlacesAtLaunch()
            refreshMarginRows() // first: a restored reply finds the Margin it answers in these rows (#473)
            writtenMarginNotice = restoreUnfinishedWrittenMargin(store: store, availableItemIDs: availableItemIDs)
            tryRefreshOfflineStorageUsage()
            diagnostics["libraryBootstrap"] = "loaded:\(rows.count)"
            reportSuccess(rows.isEmpty ? "Add a source to begin." : "Library ready.")
            // One status line holds one message, so a spoken-draft notice (#951) and this one share it.
            if let notice = [recordingDraftNotice, writtenMarginNotice].compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                reportWarning(notice)
            }
            // Read again, not from `launchData`: restoring the session above can re-prepare a manifest or finish a session.
            Task { @MainActor [weak self] in await self?.refreshAudioPreparationPresentation(announceNewCompletions: true) }
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

    /// Finishes a UI-test launch whose seed writer has reset the store and added `item`.
    private func seedUITesting(store: SQLiteSessionStore, item: Item) throws {
        self.store = store
        try configurePodcastDownloads(store: store)
        installEngine(try makeEngine(store: store))
        activeItemId = item.id
        if item.mediaType == "text" { liveSpeechFallbackItemIds.insert(item.id) }
        snapshot = SessionSnapshot()
        libraryItems = try loadLibraryRows(store: store)
        recentlyDeletedItems = []; dismissTrashUndo()
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics = ["runtimeProfile": selectedProfileId, "uiTestFixture": item.id, "speechRate": String(format: "%.2f", speechRate)]
        reportSuccess("Loaded UI test item \(item.title).")
    }

    static func shouldSeedWelcomeSample(
        libraryIsEmpty: Bool,
        storedVersion: Int,
        isUITesting: Bool
    ) -> Bool {
        libraryIsEmpty && storedVersion < welcomeSampleSeedVersion && !isUITesting
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
            dismissTrashUndo()
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics = [
                "runtimeProfile": selectedProfileId,
                "seededItems": "1",
                "database": databaseURL.lastPathComponent
            ]
            exportPreview = ""
            refreshMarginRowsInBackground()
            tryRefreshOfflineStorageUsage()
            reportSuccess("Listening queue ready.")
        } catch {
            reportFailure(error, context: "Reset and seed failed")
        }
    }

    func addSampleItem() {
        do {
            let store = try requireStore()
            let (item, map) = try makeAppOverviewSample()
            try store.saveItem(item)
            try store.saveListeningMap(map)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            activeItemId = item.id
            try refreshLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            screen = .item
            reportSuccess("Sample added.")
        } catch {
            reportFailure(error, context: "Add sample failed")
        }
    }

    func startGuidedOnboarding() {
        do {
            let store = try requireStore()
            if !(try store.hasLiveItem(id: Self.guidedOnboardingItemId)) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                UserDefaults.standard.removeObject(forKey: Self.guidedOnboardingTombstoneKey)
                try refreshLibraryRows(store: store)
            } else if try store.loadListeningMap(itemId: Self.guidedOnboardingItemId) == nil {
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            restoreOnboardingCard()
            isHelpPresented = false
            setGuidedOnboardingStage(onboardingProgress.tourResumeStage)
            startItem(id: Self.guidedOnboardingItemId)
        } catch {
            reportFailure(error, context: "Guided tour setup failed")
        }
    }
}
