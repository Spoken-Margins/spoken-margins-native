import Foundation
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitPersistence
import SessionKitSharing

/// Packet import entry points. The review, confirm and placement flow lives in `SpokenMarginsPackageImportCoordinator` (T5, #963);
/// these forwarders keep their names and the task launch shells (their weak-self captures and cleanup) here.
extension Gate1AppModel {
    func consumePendingSpokenMarginsPackageHandoffs(
        from packageStore: SpokenMarginsPackageHandoffStore
    ) throws {
        let payloadIDs = try packageStore.pendingPayloadIDs()
        diagnostics["pendingSpokenMarginsPackages"] = "\(payloadIDs.count)"
        for payloadID in payloadIDs where spokenMarginsPackageImportReview == nil {
            do {
                let packageURL = try packageStore.packageURL(payloadID: payloadID)
                let didOpen = stageSpokenMarginsPackageImport(from: packageURL)
                try packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = didOpen ? "opened" : "rejected"
            } catch {
                try? packageStore.deletePackage(payloadID: payloadID)
                diagnostics["pendingSpokenMarginsPackage:\(payloadID)"] = "rejected:\(error.localizedDescription)"
                reportFailure(error, context: "Shared Margins package could not be opened")
            }
        }
    }

    @discardableResult
    func stageSpokenMarginsPackageImport(from sourceURL: URL) -> Bool {
        switch packageImport.stage(from: sourceURL) {
        case .rejected:
            return false
        case .staged:
            return true
        case .restoreAudio(let restore):
            Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: restore.directory) }
                guard let self else { return }
                await self.packageImport.restoreAudio(restore)
                withExtendedLifetime(self) {} // the model stays retained until the work ends, as the old task body did
            }
            return true
        }
    }

    var shareLinkOpener: ShareLinkOpener { packageImport.shareLinkOpener }

    /// A tapped share link (https on the share host): download, unseal, then the usual import review (#488).
    func openShareLink(_ url: URL) {
        guard let link = ShareLinkURL(url: url) else {
            reportFailure("This isn't a Spoken Margins share link.")
            return
        }
        diagnostics["lastShareLink"] = link.key == nil ? "opening:no_key" : "opening"
        shareLinkOpener.open(
            link,
            stage: { [weak self] file in
                guard let self else { return }
                let opened = self.stageSpokenMarginsPackageImport(from: file)
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
            self?.stageSpokenMarginsPackageImport(from: packageURL)
        }
    }

    func cancelSpokenMarginsPackageImport() {
        packageImport.cancel()
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    /// Build 23 presentation code calls this seam instead of asking the user to
    /// reopen the package and repeat integrity verification.
    func refreshSpokenMarginsPackageImportAfterAddingSource() {
        packageImport.refreshAfterAddingSource()
    }

    func confirmSpokenMarginsPackageImport() {
        guard let review = packageImport.beginConfirmation() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.packageImport.confirm(review)
            withExtendedLifetime(self) {}
        }
    }

    func prepareImportedLocalAudioBridges(itemId: String) {
        guard let store, let item = try? store.loadItem(id: itemId),
              item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream || item.media?.sourceType == .generatedTTSPrerendered,
              let projection = try? store.loadResolvedListeningMapProjection(itemId: itemId),
              let proposals = try? store.loadPortableListeningMapProposals(itemId: itemId),
              let proposal = proposals.first(where: { $0.id == projection.proposalId }),
              preparingLocalAudioMapItems.insert(itemId).inserted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.preparingLocalAudioMapItems.remove(itemId) }
            do {
                for scene in proposal.scenes where scene.eligibility == .eligible {
                    try Task.checkCancellation()
                    guard try await self.prepareSummaryBridgeAsset(
                        itemId: itemId, proposalId: proposal.id, scene: scene, store: store
                    ) != nil else {
                        throw SessionKitError.persistenceFailed("Summary audio was not prepared")
                    }
                    self.updateSkimAvailability()
                }
                self.diagnostics["localAudioSkim:\(itemId)"] = "ready"
            } catch {
                self.diagnostics["localAudioSkim:\(itemId)"] = "failed:\(error.localizedDescription)"
                self.reportWarning("Some Skim summaries are not ready. Reopen the item to retry, or reimport the package to restore its supplied voices.")
            }
        }
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
        item.mediaType == "audiobook" ? SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: (try? store?.loadOwnedOfflineAssets()) ?? []) : nil
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
            publishError: { [weak model] in model?.spokenMarginsPackageImportError = $0 }
        )
    }
}
