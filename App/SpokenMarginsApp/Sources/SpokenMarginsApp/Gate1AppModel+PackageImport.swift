import Foundation
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitPersistence
import SessionKitSharing

/// Packet import entry points. The review, confirm and placement flow lives in `SpokenMarginsPackageImportCoordinator` (T5, #963);
/// these forwarders keep their names and the task launch shells (their weak-self captures and cleanup) here.
extension Gate1AppModel {
    /// Opens the files the Share extension left in the inbox. A file that needs a newer app stays, so the listener
    /// can open it after updating; it is tried again once per app version, which tells the listener, and
    /// goes after 30 days or when five newer ones are kept (#1983). A file shown for review stays until the listener
    /// imports or cancels it, so it survives the app being killed first (#2123); while any review shows, nothing more
    /// is staged, so a kept file reopens once per launch. Every other file is removed once it has been tried.
    func consumePendingSpokenMarginsPackageHandoffs(
        from packageStore: SpokenMarginsPackageHandoffStore,
        keptNotices: KeptPackageNotices = KeptPackageNotices(),
        appVersion: String = KeptPackageNotices.currentAppVersion,
        now: Date = Date()
    ) async throws {
        packageImport.sweepOrphanedFoldersOnce()
        // The inbox is shared with the Share extension, so listing and deleting its files can wait on it; they run off the
        // main actor (#2510). The staging below is awaited too.
        let payloadIDs = try await Self.offMain { try packageStore.pendingPayloadIDs() }
        diagnostics["pendingSpokenMarginsPackages"] = "\(payloadIDs.count)"
        for payloadID in payloadIDs where spokenMarginsPackageImportReview == nil {
            do {
                if keptNotices.hasExpired(payloadID: payloadID, now: now) {
                    try await Self.offMain { try packageStore.deletePackage(payloadID: payloadID) }
                    keptNotices.forget(payloadID: payloadID)
                    diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "expired"
                    continue
                }
                let announces = keptNotices.shouldAnnounce(payloadID: payloadID, appVersion: appVersion)
                // The same build can't open what it already couldn't, so a kept file is staged again only when
                // the app version has changed. Staging copies the whole file, which is too heavy for every foreground.
                if keptNotices.isKept(payloadID: payloadID), !announces {
                    diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "kept_needs_newer_app"
                    continue
                }
                let packageURL = try await Self.offMain { try packageStore.packageURL(payloadID: payloadID) }
                // The release runs when the listener imports or cancels, which must leave no file to open again after a
                // kill (#2123), so this one stays a single delete in place.
                let outcome = await stageSpokenMarginsPackage(from: packageURL, announcesRejection: announces) {
                    try? packageStore.deletePackage(payloadID: payloadID)
                    keptNotices.forget(payloadID: payloadID)
                }
                if outcome == .rejectedNeedsNewerApp {
                    keptNotices.noteKept(payloadID: payloadID, appVersion: appVersion, now: now)
                    diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "kept_needs_newer_app"
                    continue
                }
                if outcome == .opened {
                    diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "opened"
                    continue
                }
                // A staging cut short by a cancelled caller says nothing about the file: keep it for the next launch.
                guard !Task.isCancelled else { return }
                try await Self.offMain { try packageStore.deletePackage(payloadID: payloadID) }
                keptNotices.forget(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "rejected"
            } catch {
                try? await Self.offMain { try packageStore.deletePackage(payloadID: payloadID) }
                keptNotices.forget(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "rejected:\(error.localizedDescription)"
                reportFailure(error, context: "Shared Margins package could not be opened")
            }
        }
        for payloadID in keptNotices.overflowIDs() {
            try? await Self.offMain { try packageStore.deletePackage(payloadID: payloadID) }
            keptNotices.forget(payloadID: payloadID)
        }
        keptNotices.forgetAll(except: Set(try await Self.offMain { try packageStore.pendingPayloadIDs() }))
    }

    enum SpokenMarginsPackageStageOutcome: Equatable {
        case opened
        case rejected
        case rejectedNeedsNewerApp
    }

    @discardableResult
    func stageSpokenMarginsPackageImport(from sourceURL: URL) async -> Bool {
        await stageSpokenMarginsPackage(from: sourceURL, announcesRejection: true) == .opened
    }

    /// Opens a packet from a place that cannot wait for the staging (a URL the system handed over). The staging
    /// searches the Library off the main actor, so the review shows a moment later; `waitForPackageStaging` is for tests.
    func stageSpokenMarginsPackageImportInBackground(from sourceURL: URL) {
        packageImport.launch { [weak self] in
            _ = await self?.stageSpokenMarginsPackageImport(from: sourceURL)
        }
    }

    func waitForPackageStaging() async {
        await packageImport.waitForStaging()
    }

    func stageSpokenMarginsPackage(
        from sourceURL: URL, announcesRejection: Bool, releaseSource: (@MainActor () -> Void)? = nil
    ) async -> SpokenMarginsPackageStageOutcome {
        switch await packageImport.stage(from: sourceURL, announcesRejection: announcesRejection, releaseSource: releaseSource) {
        case .rejected(let needsNewerApp):
            return needsNewerApp ? .rejectedNeedsNewerApp : .rejected
        case .staged:
            return .opened
        case .restoreAudio(let restore):
            Task { @MainActor [weak self, labels = hangTelemetry.labels] in
                // The folder holds the extracted audio, so its removal runs off the main actor (#2510), still after the restore ends.
                defer { labels.scoped("restoreAudioCleanup") { Task.detached(priority: .utility) { _ = try? FileManager.default.removeItem(at: restore.directory) } } }
                guard let self else { return }
                await self.packageImport.restoreAudio(restore)
                withExtendedLifetime(self) {} // the model stays retained until the work ends, as the old task body did
            }
            return .opened
        }
    }

    var shareLinkOpener: ShareLinkOpener { packageImport.shareLinkOpener }

    /// A tapped share link (https on the share host): download, unseal, then the usual import review (#488).
    func openShareLink(_ url: URL) {
        guard let link = ShareLinkURL(url: url) else {
            reportFailure("This isn't a Spoken Margins share link.")
            return
        }
        withdrawRetryOffer("shareLink:\(link.id)")
        diagnostics["lastShareLink"] = link.key == nil ? "opening:no_key" : "opening"
        shareLinkOpener.open(
            link,
            stage: { [weak self] file in
                guard let self else { return }
                let opened = await self.stageSpokenMarginsPackageImport(from: file)
                self.diagnostics["lastShareLink"] = opened ? "opened" : "rejected"
            },
            fail: { [weak self] message, retryable in
                self?.diagnostics["lastShareLink"] = "failed"
                let retry: UserFeedbackEvent.Retry? = retryable
                    ? .init(key: "shareLink:\(link.id)") { [weak self] in self?.openShareLink(url) }
                    : nil
                self?.reportFailure(message, retry: retry)
            }
        )
    }

    func createRecipientTestSessionFromLastSharedPackage() {
        guard let packageURL = sharedSpokenMarginsPackageURL else {
            reportFailure("The last shared package is unavailable.")
            return
        }
        isSharingInterjectionsPresented = false
        isSharedSpokenMarginsPackagePresented = false
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.stageSpokenMarginsPackageImport(from: packageURL)
        }
    }

    func cancelSpokenMarginsPackageImport() {
        packageImport.cancel()
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    /// Build 23 presentation code calls this seam instead of asking the user to
    /// reopen the package and repeat integrity verification.
    func refreshSpokenMarginsPackageImportAfterAddingSource() {
        packageImport.launchRefreshAfterAddingSource()
    }

    func confirmSpokenMarginsPackageImport() {
        guard let review = packageImport.beginConfirmation() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.packageImport.confirm(review)
            withExtendedLifetime(self) {}
        }
    }

    /// Prepares the summary audio Skim plays for each scene of a mapped item; every open runs it. The map and the saved
    /// summaries are read once, off the main thread, and only scenes whose summary isn't saved are prepared (#2255).
    /// This used to read the whole asset table and reload Skim once per scene on the main thread, even with every
    /// summary saved, and a 77-minute episode froze the app for 20 s on open.
    func prepareImportedLocalAudioBridges(itemId: String) {
        guard let store else { return }
        // A call while a pass runs (the map was just placed, say) is kept, and runs once that pass ends.
        guard preparingLocalAudioMapItems[itemId] == nil else { preparingLocalAudioMapItems[itemId] = true; return }
        preparingLocalAudioMapItems[itemId] = false
        let assetID = summaryBridgeAssetIDs(itemId: itemId)
        let supportDirectory = try? applicationSupportDirectory()
        Task { @MainActor [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                () -> (proposal: PortableListeningMapProposalArtifact, needed: [PortableListeningMapScene], saved: Set<String>)? in
                guard let inventory = try? Gate1AppModel.localAudioBridgeInventory(itemId: itemId, store: store) else { return nil }
                let proposalId = inventory.proposal.id
                let needed = inventory.scenesNeedingAudio(assetID: { assetID(proposalId, $0) }, fileExists: {
                    Gate1AppModel.resolvedApplicationSupportAssetURL(for: $0, applicationSupportDirectory: supportDirectory) != nil
                })
                let neededIDs = Set(needed.map(\.id))
                let saved = inventory.proposal.scenes.filter { $0.eligibility == .eligible && !neededIDs.contains($0.id) }
                return (inventory.proposal, needed, Set(saved.map { assetID(proposalId, $0) }))
            }.value
            guard let self else { return }
            defer {
                if self.preparingLocalAudioMapItems.removeValue(forKey: itemId) == true { self.prepareImportedLocalAudioBridges(itemId: itemId) }
            }
            guard let plan else { return }
            let (proposal, needed) = (plan.proposal, plan.needed)
            var savedAssetIDs = plan.saved
            do {
                for scene in needed {
                    try Task.checkCancellation()
                    guard let asset = try await self.prepareSummaryBridgeAsset(
                        itemId: itemId, proposalId: proposal.id, scene: scene, store: store
                    ) else {
                        throw SessionKitError.persistenceFailed("Summary audio was not prepared")
                    }
                    savedAssetIDs.insert(asset.id)
                    // A summary was just saved; Skim can play it now instead of after the whole pass.
                    self.hangTelemetry.labels.scoped("localAudioBridges.skim") { self.updateSkimAvailability() }
                }
                self.diagnostics["localAudioSkim:\(itemId)"] = "ready"
            } catch {
                self.diagnostics["localAudioSkim:\(itemId)"] = "failed:\(error.localizedDescription)"
                self.reportWarning("Some Skim summaries are not ready. Reopen the item to retry, or reimport the package to restore its supplied voices.")
            }
            // A pass that stops early may still have adopted supplied summaries; Skim reads what was committed (#2184),
            // and reloads only when what it loaded lacks one of them.
            self.hangTelemetry.labels.scoped("localAudioBridges.skim") {
                self.skimBridge.summaryAssetsSaved(itemId: itemId, assetIDs: savedAssetIDs)
            }
        }
    }

    /// The map of a media item and its saved summary assets, read once; nil when it isn't media or has no placed map.
    nonisolated static func localAudioBridgeInventory(itemId: String, store: SQLiteSessionStore) throws -> SummaryBridgeInventory? {
        let sourceType = try store.loadItem(id: itemId).media?.sourceType
        guard sourceType == .nativeMediaFile || sourceType == .remoteStream || sourceType == .generatedTTSPrerendered else { return nil }
        return try SummaryBridgeInventory.read(
            loadProposal: {
                guard let projection = try store.loadResolvedListeningMapProjection(itemId: itemId) else { return nil }
                return try store.loadPortableListeningMapProposals(itemId: itemId).first(where: { $0.id == projection.proposalId })
            },
            loadAssets: { try store.loadOwnedOfflineAssets() }
        )
    }

    func acquirePodcastForImportedPackage(_ item: SharedItemIdentity) async throws -> String {
        guard let canonicalURL = item.canonicalURL,
              SharedPodcastResolutionPolicy.hasReference(item) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_has_no_reference")
        }
        let request = LinkResolutionRequest(
            id: "shared-package-\(UUID().uuidString)",
            inputURL: canonicalURL,
            sourceSurface: "spoken_margins_package",
            createdAt: Date()
        )
        var result: LinkResolutionResult
        do {
            if let sourceLinkResolver {
                result = try sourceLinkResolver.resolve(request)
            } else {
                result = try await PublicPodcastLinkResolver().resolveAsync(request)
            }
        } catch {
            // Keep the existing resolver path first. Some publisher pages reject
            // automated requests even when the packet has the exact enclosure.
            // In that case, use its reference through the same source persistence
            // path; anchor placement still needs recipient evidence.
            guard let packageResult = SharedPodcastResolutionPolicy.packageReferenceResolution(item: item, request: request) else {
                throw error
            }
            diagnostics["lastSharedPodcastAcquisition"] = "package_reference_after_resolution_failure"
            result = packageResult
        }
        let settled = try SharedPodcastResolutionPolicy.settle(result, item: item, request: request)
        result = settled.result
        if let diagnostic = settled.diagnostic {
            diagnostics["lastSharedPodcastAcquisition"] = diagnostic
        }
        guard result.status == .playable,
              let importedItem = try persistResolvedSourceLinkInBackground(request: request, result: result) else {
            throw SessionKitError.persistenceFailed("shared_podcast_item_not_created")
        }
        return importedItem.id
    }

    func localAudiobookDigest(for item: Item) -> String? {
        item.mediaType == "audiobook" ? SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: (try? store?.loadOwnedOfflineAssets(itemId: item.id)) ?? []) : nil
    }
}

extension SpokenMarginsPackageImportCoordinator.Environment {
    /// The live environment: the model's store, Library, downloads, feedback and diagnostics, and the views' copy of the state.
    @MainActor
    static func live(model: Gate1AppModel) -> Self {
        Self(
            requireStore: { [weak model] in
                guard let model else { throw CancellationError() }
                return try model.requireStore()
            },
            applicationSupportDirectory: { [weak model] in
                guard let model else { throw CancellationError() }
                return try model.applicationSupportDirectory()
            },
            bootstrapLibrary: { [weak model] in model?.bootstrapLibraryIfNeeded() },
            recordDiagnostic: { [weak model] key, value in model?.diagnostics[key] = value },
            reportSuccess: { [weak model] in model?.reportSuccess($0) },
            reportConfirmation: { [weak model] in model?.reportConfirmation($0) },
            reportFailureMessage: { [weak model] in model?.reportFailure($0) },
            reportFailure: { [weak model] error, context in model?.reportFailure(error, context: context) },
            openItem: { [weak model] in model?.openItem(id: $0) },
            showImportedItem: { [weak model] itemId, store in
                guard let model else { return }
                model.activeItemId = itemId
                model.libraryItems = try model.loadLibraryRows(store: store)
                model.selectedItem = try model.loadItemDetail(id: itemId, store: store)
                model.screen = .item
            },
            recordPacketImport: { [weak model] itemId, packetId, marginCount in
                model?.listeningSignals.packetImport(itemId: itemId, packetId: packetId, marginCount: marginCount)
            },
            localAudiobookDigest: { [weak model] in model?.localAudiobookDigest(for: $0) },
            ownedAudiobookURL: { [weak model] in model?.resolvedOwnedAudiobookURL(for: $0) },
            validatedLocalURL: { [weak model] in model?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) },
            registerRemoteDownload: { [weak model] itemId, remoteURL in
                model?.podcastDownloadCoordinator?.register(itemId: itemId, remoteURL: remoteURL, userInitiated: true)
            },
            resolvePodcastCommentary: { [weak model] itemId, localURL in
                model?.resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
            },
            acquirePodcast: { [weak model] item in
                guard let model else { throw CancellationError() }
                return try await model.acquirePodcastForImportedPackage(item)
            },
            acquireArticle: { [weak model] item in
                guard let model else { throw CancellationError() }
                return try await model.acquireArticleForImportedPackage(item)
            },
            offlineLedger: { [weak model] store, rootDirectory in
                guard let model else { return OfflineStorageLedger(repository: store, rootDirectory: rootDirectory) }
                return model.requireOfflineLedger(store: store, rootDirectory: rootDirectory)
            },
            summaryBridgeAssetID: { [weak model] itemId, proposalId, sceneId, suppliedAssetId in
                model?.summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: sceneId, suppliedAssetId: suppliedAssetId) ?? ""
            },
            selectedItemID: { [weak model] in model?.selectedItem.id ?? "" },
            refreshSelectedItem: { [weak model] in model?.refreshSelectedItem() },
            prepareLocalAudioBridges: { [weak model] in model?.prepareImportedLocalAudioBridges(itemId: $0) },
            consumeForcedSourceMiss: { [weak model] in
                guard let model, model.shouldForceFirstSharedSourceMissForUITesting else { return false }
                model.shouldForceFirstSharedSourceMissForUITesting = false
                return true
            },
            publishReview: { [weak model] in model?.spokenMarginsPackageImportReview = $0 },
            publishIsImporting: { [weak model] in model?.isImportingSpokenMarginsPackage = $0 },
            publishError: { [weak model] in model?.spokenMarginsPackageImportError = $0 },
            attachListeningMap: { [weak model] map in try model?.attachSharedTextListeningMap(map) },
            labels: model.hangTelemetry.labels
        )
    }
}
