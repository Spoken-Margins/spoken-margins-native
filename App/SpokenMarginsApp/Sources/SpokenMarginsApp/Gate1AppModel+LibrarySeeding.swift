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
    func bootstrapLibraryIfNeeded() {
        guard pendingUITestingSeed != nil || (libraryItems.isEmpty && store == nil) else { return }
        do {
            let store = try requireStore()
            libraryAccessError = nil
            purgeExpiredEpisodeMapPreparationJobs(store: store)
            let seed = pendingUITestingSeed ?? UITestingLaunchSeed.none; pendingUITestingSeed = nil
            switch seed {
            case .none, .keepLibrary: break
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
                isUITesting: UITestingHooks.isActive
            ) {
                let (item, map) = try makeAppOverviewSample()
                try store.saveItem(item)
                try store.saveListeningMap(map)
                rows = try loadLibraryRows(store: store)
                diagnostics["welcomeSample"] = "seeded:v\(Self.welcomeSampleSeedVersion)"
            }
            if !UITestingHooks.isActive,
               !UserDefaults.standard.bool(forKey: Self.guidedOnboardingTombstoneKey),
               UserDefaults.standard.integer(forKey: Self.guidedOnboardingSeedVersionKey) < 1,
               !(try store.listItems()).contains(where: { $0.id == Self.guidedOnboardingItemId }) {
                try store.saveItem(Self.makeBundledGuidedOnboardingItem())
                try store.saveListeningMap(Self.makeBundledGuidedOnboardingMap())
                UserDefaults.standard.set(1, forKey: Self.guidedOnboardingSeedVersionKey)
                rows = try loadLibraryRows(store: store)
                diagnostics["guidedOnboardingItem"] = "bundled_fallback_seeded"
            }
            if !UITestingHooks.isActive,
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
            try recoverInterruptedAIJobs(store: store, rows: rows); settleOrphanedTranscriptions(store: store)
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
}
