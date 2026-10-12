import Foundation
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitPersistence
import SessionKitSharing

/// Packet import, recipient matching and local audio adoption. Moved out of `Gate1AppModel.swift` unchanged (#956).
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
        var workingDirectory: URL?
        do {
            bootstrapLibraryIfNeeded()
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let root = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/IncomingPackages/\(UUID().uuidString)", directoryHint: .isDirectory)
            workingDirectory = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let copiedPackage = root.appending(path: "package.spokenmargins")
            try FileManager.default.copyItem(at: sourceURL, to: copiedPackage)
            let contents = try SpokenMarginsPackageArchive.read(
                from: copiedPackage,
                extractingAssetsTo: root.appending(path: "assets", directoryHint: .isDirectory)
            )
            guard let digest = contents.manifest.contentDigest else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
            let store = try requireStore()
            if let existing = try store.loadImportedCommentaryLayer(packageDigest: digest),
               existing.sourceResolutionStatus != .wrongSource,
               let associatedItemId = existing.itemId,
               let associatedItem = try? store.loadItem(id: associatedItemId),
               associatedItem.deletedAt == nil,
               SharedPacketItemMatcher.layerHasValidItemAssociation(existing, item: associatedItem,
                   ownedAudiobookDigest: localAudiobookDigest(for: associatedItem)) {
                if let itemId = existing.itemId {
                    openItem(id: itemId)
                    if let item = try? store.loadItem(id: itemId), item.mediaType == "audiobook" {
                        Task { @MainActor [weak self] in
                            defer { try? FileManager.default.removeItem(at: root) }
                            guard let self else { return }
                            do {
                                try await self.placeOnOwnedAudio(item, contents: contents,
                                    admission: self.verifyLocalAudioForImport(item, contents: contents))
                                self.reportSuccess("Restored this listening package. Playback has not started.")
                            } catch { self.reportFailure(error, context: "Restoring listening package failed") }
                        }
                        return true
                    }
                    if let localURL = podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                    reportSuccess("These shared Margins are already in your library. Playback has not started.")
                } else {
                    reportSuccess("These shared Margins are already in your library.")
                }
                diagnostics["lastSpokenMarginsPackageImport"] = "duplicate:\(digest)"
                try? FileManager.default.removeItem(at: root)
                return true
            }
            let matchingItemId = try matchingItemID(for: contents.manifest.item, store: store)
            spokenMarginsPackageImportError = nil
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: copiedPackage,
                extractionDirectory: root,
                contents: contents,
                matchingItemId: matchingItemId
            )
            if try store.loadImportedCommentaryLayer(packageDigest: digest) == nil {
                diagnostics["lastSpokenMarginsPackageImport"] = "previewed:\(digest)"
            } else {
                diagnostics["lastSpokenMarginsPackageImport"] = "repair_previewed:\(digest)"
            }
            return true
        } catch {
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
            diagnostics["lastSpokenMarginsPackageImport"] = "rejected:\(SharedMarginsImportMessage.diagnosticDetail(error))"
            reportFailure(SharedMarginsImportMessage.userFacing(error))
            return false
        }
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
        guard !isImportingSpokenMarginsPackage else { return }
        let directory = spokenMarginsPackageImportReview?.extractionDirectory
        spokenMarginsPackageImportReview = nil
        spokenMarginsPackageImportError = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    /// Build 23 presentation code calls this seam instead of asking the user to
    /// reopen the package and repeat integrity verification.
    func refreshSpokenMarginsPackageImportAfterAddingSource() {
        guard let review = spokenMarginsPackageImportReview,
              review.requiresRecipientItem,
              !isImportingSpokenMarginsPackage else { return }
        do {
            let store = try requireStore()
            let matchingItemId = try matchingItemID(for: review.contents.manifest.item, store: store)
            spokenMarginsPackageImportReview = SpokenMarginsPackageImportReview(
                packageURL: review.packageURL,
                extractionDirectory: review.extractionDirectory,
                contents: review.contents,
                matchingItemId: matchingItemId
            )
            if matchingItemId == nil {
                spokenMarginsPackageImportError = "That source does not match the item described by this package yet. Add the same item or cancel the import."
            } else {
                spokenMarginsPackageImportError = nil
                reportConfirmation("Source matched. Review the shared Margins before importing.")
            }
        } catch {
            spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
            diagnostics["lastSpokenMarginsPackageImport"] = "source_reconciliation_failed:\(error.localizedDescription)"
        }
    }

    func confirmSpokenMarginsPackageImport() {
        guard let review = spokenMarginsPackageImportReview,
              !isImportingSpokenMarginsPackage else { return }
        guard !review.requiresRecipientItem else {
            spokenMarginsPackageImportError = "This package does not include the item. Add the matching source, then return to this pending import."
            return
        }
        isImportingSpokenMarginsPackage = true
        spokenMarginsPackageImportError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let itemId: String?
                if let matching = review.matchingItemId {
                    itemId = matching
                } else if review.contents.manifest.itemTransport.kind == .embeddedText {
                    itemId = try self.installEmbeddedItem(from: review.contents, store: store)
                } else if review.contents.manifest.item.itemType == .podcast {
                    itemId = try await self.acquirePodcastForImportedPackage(review.contents.manifest.item)
                } else {
                    itemId = try await self.acquireArticleForImportedPackage(review.contents.manifest.item)
                }
                let item = try itemId.map { try store.loadItem(id: $0) }
                let localItem = item.map { SharedPacketItemMatcher.localIdentity(for: $0, ownedAudiobookDigest: self.localAudiobookDigest(for: $0)) }
                var localAudioAdmission: LocalAudioPacketAdmission?
                if let item, item.mediaType == "audiobook" {
                    localAudioAdmission = try await self.verifyLocalAudioForImport(item, contents: review.contents)
                }
                let itemText = item?.text
                let disposition: ImportedCommentaryImportDisposition
                if let digest = review.contents.manifest.contentDigest,
                   let existing = try store.loadImportedCommentaryLayer(packageDigest: digest) {
                    try SpokenMarginsPackageImporter.repairAssociation(
                        existing: existing,
                        contents: review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                    if let itemId { self.diagnostics["lastSpokenMarginsPackageRepair"] = "reassociated:\(existing.id):\(itemId)" }
                    disposition = .duplicate(existingLayerId: existing.id)
                } else {
                    disposition = try SpokenMarginsPackageImporter.importPackage(
                        review.contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                }
                switch disposition {
                case .duplicate(let existingLayerId):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "duplicate_layer:\(existingLayerId)"
                case .imported(let layerId, let interjectionIds):
                    self.diagnostics["lastSpokenMarginsPackageImport"] = "imported:\(layerId):\(interjectionIds.count)"
                    self.listeningSignals.packetImport(itemId: itemId, packetId: review.contents.manifest.packageId, marginCount: interjectionIds.count)
                }
                if let itemId {
                    self.activeItemId = itemId
                    self.libraryItems = try self.loadLibraryRows(store: store)
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                    self.screen = .item
                    if let item,
                       item.media?.sourceType == .remoteStream,
                       let rawURL = item.media?.url,
                       let remoteURL = URL(string: rawURL) {
                        self.podcastDownloadCoordinator?.register(
                            itemId: itemId,
                            remoteURL: remoteURL,
                            userInitiated: true
                        )
                    }
                    if let item, let localAudioAdmission {
                        try await self.placeOnOwnedAudio(item, contents: review.contents, admission: localAudioAdmission)
                    } else if let localURL = self.podcastDownloadCoordinator?.validatedLocalURL(for: itemId) {
                        self.resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
                    }
                }
                self.spokenMarginsPackageImportReview = nil
                self.isImportingSpokenMarginsPackage = false
                self.reportConfirmation("Imported shared Margins. Playback has not started.")
            } catch {
                self.isImportingSpokenMarginsPackage = false
                self.spokenMarginsPackageImportError = SharedMarginsImportMessage.userFacing(error)
                self.diagnostics["lastSpokenMarginsPackageImport"] = "failed:\(error.localizedDescription)"
                self.reportFailure(error, context: "Shared Margins import failed")
            }
        }
    }

    private func verifyLocalAudioForImport(_ item: Item, contents: VerifiedSpokenMarginsPackage) async throws -> LocalAudioPacketAdmission {
        guard let url = resolvedOwnedAudiobookURL(for: item) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local source audio is unavailable")
        }
        let actualDigest = try await Task.detached(priority: .utility) {
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        }.value
        return try LocalAudioPacketAdmission.admitted(
            contents, recipient: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item)), itemId: item.id, actualDigest: actualDigest)
    }

    /// Exact maps project at the sender's times; a podcast packet on the listener's copy is placed like a download.
    private func placeOnOwnedAudio(_ item: Item, contents: VerifiedSpokenMarginsPackage, admission: LocalAudioPacketAdmission) async throws {
        if admission == .exactEdition { return try await activateImportedLocalAudioMaps(item: item, contents: contents) }
        if let url = resolvedOwnedAudiobookURL(for: item) { resolveImportedPodcastCommentary(itemId: item.id, localURL: url) }
    }

    private func activateImportedLocalAudioMaps(item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        let store = try requireStore()
        let recipient = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item))
        for proposal in contents.listeningMapProposals {
            let projection = try ExactLocalAudioImport.projection(
                proposal: proposal, source: contents.manifest.item, recipient: recipient, itemId: item.id
            )
            for scene in proposal.scenes where scene.summaryAssetId != nil {
                try await adoptSuppliedSummary(scene: scene, proposalId: proposal.id, itemId: item.id, contents: contents, store: store)
            }
            try store.savePortableListeningMapProposal(proposal, itemId: item.id)
            try store.saveResolvedListeningMapProjection(projection)
        }
        if selectedItem.id == item.id { refreshSelectedItem() }
        prepareImportedLocalAudioBridges(itemId: item.id)
    }

    private func adoptSuppliedSummary(
        scene: PortableListeningMapScene, proposalId: String, itemId: String,
        contents: VerifiedSpokenMarginsPackage, store: SQLiteSessionStore
    ) async throws {
        guard let suppliedID = scene.summaryAssetId,
              let descriptor = contents.manifest.assets.first(where: { $0.id == suppliedID && $0.role == SpokenMarginsAssetRole.summaryVoice }),
              let sourceURL = contents.extractedAssetURLs[suppliedID],
              let checksum = descriptor.sha256, let byteCount = descriptor.byteCount else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Supplied summary audio is unavailable")
        }
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: suppliedID)
        let relativePath = "SpokenMargins/EpisodeMaps/\(safePodcastEvidenceComponent(itemId))/SummaryBridges/\(assetID).m4a"
        let support = try applicationSupportDirectory()
        let destination = support.appending(path: relativePath)
        let ledger = requireOfflineLedger(store: store, rootDirectory: support)
        let reservation = try await ledger.reserve(ownerId: assetID, byteCount: Int64(byteCount))
        do {
            try await Task.detached(priority: .utility) {
                guard try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: sourceURL) == checksum else {
                    throw SpokenMarginsPackageArchiveError.invalidAsset(suppliedID)
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: sourceURL).write(to: destination, options: .atomic)
            }.value
            try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                id: assetID, itemId: itemId, category: .summaryBridge, relativePath: relativePath,
                byteCount: Int64(byteCount), checksumSHA256: checksum, isReproducible: false
            ))
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
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

    private func installEmbeddedItem(
        from contents: VerifiedSpokenMarginsPackage,
        store: SQLiteSessionStore
    ) throws -> String {
        guard contents.manifest.itemTransport.kind == .embeddedText,
              let artifactID = contents.manifest.itemTransport.embeddedArtifactId,
              let embedded = contents.embeddedTextItems.first(where: { $0.id == artifactID }),
              let digest = contents.manifest.contentDigest else {
            throw SessionKitError.persistenceFailed("shared_embedded_item_is_unavailable")
        }
        let itemID = "item-shared-\(digest.prefix(20))"
        let item = Item(
            id: itemID,
            title: contents.manifest.item.title,
            mediaType: "text",
            text: embedded.text,
            externalReference: "shared-package:\(contents.manifest.packageId)",
            status: "ready",
            externalReferenceType: "spoken_margins_package"
        )
        try store.seed(item: item)
        return itemID
    }

    private func acquirePodcastForImportedPackage(_ item: SharedItemIdentity) async throws -> String {
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

    private func matchingItemID(
        for itemIdentity: SharedItemIdentity,
        store: SQLiteSessionStore
    ) throws -> String? {
        if shouldForceFirstSharedSourceMissForUITesting {
            shouldForceFirstSharedSourceMissForUITesting = false
            diagnostics["uiTestSharedSourceMiss"] = "forced_once"
            return nil
        }
        return SharedPacketItemMatcher.matchingItemId(
            for: itemIdentity, among: try store.listItems(), ownedAudiobookDigest: localAudiobookDigest(for:))
    }

    func localAudiobookDigest(for item: Item) -> String? {
        item.mediaType == "audiobook" ? SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: (try? store?.loadOwnedOfflineAssets()) ?? []) : nil
    }
}
