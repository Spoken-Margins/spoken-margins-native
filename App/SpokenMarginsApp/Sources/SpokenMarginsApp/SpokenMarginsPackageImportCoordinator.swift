import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing

/// The "review, confirm, place a shared packet" flow, moved out of `Gate1AppModel+PackageImport.swift` (T5, #963).
/// It owns the three pieces of import state and everything that touches the packet's files; the model keeps
/// forwarders under today's names, the four task launch shells, and the publication of the state to views.
///
/// The coordinator reaches the app only through `Environment`, so its tests run with a real SQLite store and real
/// packet files but without a `Gate1AppModel`.
/// - Success keeps `SpokenMargins/IncomingPackages/<uuid>/assets` for good. The folder is removed only by
///   `cancel`, a failed stage, duplicate staging and the model's restore-audio task, and by the launch sweep for a
///   folder an app kill left behind that no imported Margin uses (#2154).
/// - One review shows at a time (#2122). A packet opened while one is showing, or importing, waits behind it in
///   `PacketReviewQueue` and comes up when that one is imported or cancelled; it is never replaced or dropped.
/// - The file a packet was opened from is released (the Share inbox copy deleted) only when the packet is imported,
///   cancelled or already in the library, never when its review opens, so a packet survives the app being killed
///   before Import (#2123).
/// - `confirm` works on the review captured when it began. Its success ends only that review, and its error is
///   shown only while that review is still the one showing.
@MainActor
final class SpokenMarginsPackageImportCoordinator {
    /// Opens tapped share links into this flow (#488); the model reaches it as `shareLinkOpener`.
    let shareLinkOpener = ShareLinkOpener()
    /// What the flow needs from the app. The live one is `Environment.live(model:)`.
    struct Environment {
        var requireStore: @MainActor () throws -> SQLiteSessionStore
        var applicationSupportDirectory: @MainActor () throws -> URL
        var bootstrapLibrary: @MainActor () -> Void
        var recordDiagnostic: @MainActor (_ key: String, _ value: String) -> Void
        var reportSuccess: @MainActor (String) -> Void
        var reportConfirmation: @MainActor (String) -> Void
        var reportFailureMessage: @MainActor (String) -> Void
        var reportFailure: @MainActor (_ error: Error, _ context: String) -> Void
        var openItem: @MainActor (String) -> Void
        /// Makes the imported item the open one: active id, Library rows, item detail, then the item screen, in that order.
        var showImportedItem: @MainActor (_ itemId: String, _ store: SQLiteSessionStore) throws -> Void
        var recordPacketImport: @MainActor (_ itemId: String?, _ packetId: String, _ marginCount: Int) -> Void
        var localAudiobookDigest: @MainActor (Item) -> String?
        var ownedAudiobookURL: @MainActor (Item) -> URL?
        var validatedLocalURL: @MainActor (_ itemId: String) -> URL?
        var registerRemoteDownload: @MainActor (_ itemId: String, _ remoteURL: URL) -> Void
        var resolvePodcastCommentary: @MainActor (_ itemId: String, _ localURL: URL) -> Void
        var acquirePodcast: @MainActor (SharedItemIdentity) async throws -> String
        var acquireArticle: @MainActor (SharedItemIdentity) async throws -> String
        var offlineLedger: @MainActor (_ store: SQLiteSessionStore, _ rootDirectory: URL) -> OfflineStorageLedger
        var summaryBridgeAssetID: @MainActor (_ itemId: String, _ proposalId: String, _ sceneId: String, _ suppliedAssetId: String?) -> String
        var selectedItemID: @MainActor () -> String
        var refreshSelectedItem: @MainActor () -> Void
        var prepareLocalAudioBridges: @MainActor (_ itemId: String) -> Void
        /// True once, when a UI test forces the first shared source to miss.
        var consumeForcedSourceMiss: @MainActor () -> Bool
        /// The views' copy of the state. Called synchronously, once per change, in the order the changes happen.
        var publishReview: @MainActor (SpokenMarginsPackageImportReview?) -> Void
        var publishIsImporting: @MainActor (Bool) -> Void
        var publishError: @MainActor (String?) -> Void
        /// Saves a shared Listening Map for a text item and tells a running session about it. Nil saves straight to the store.
        var attachListeningMap: (@MainActor (ListeningMap) throws -> Void)? = nil
    }

    enum StageResult {
        /// `needsNewerApp`: the file is fine but uses something this version doesn't know, so the caller keeps
        /// it for the listener to open after updating (#1983).
        case rejected(needsNewerApp: Bool)
        case staged
        /// An already-imported listening package on owned audio. The caller launches the task that places it
        /// and removes `directory` when that task ends.
        case restoreAudio(RestoreAudio)
    }

    struct RestoreAudio {
        let item: Item
        let contents: VerifiedSpokenMarginsPackage
        let directory: URL
    }

    private let environment: Environment
    private var isAdoptingFromViews = false
    private var didSweepOrphanedFolders = false
    /// Folders handed to a restore-audio task that has not finished with them; the sweep leaves them alone.
    private var restoringFolders: Set<String> = []

    /// Told to the listener when a packet waits behind the one already showing (#2122).
    static let waitingMessage = "Another shared packet is waiting. It opens after you finish this one."

    private var queue = PacketReviewQueue<SpokenMarginsPackageImportReview>() {
        didSet {
            guard queue.showing?.id != oldValue.showing?.id, !isAdoptingFromViews else { return }
            environment.publishReview(queue.showing)
        }
    }
    var review: SpokenMarginsPackageImportReview? { queue.showing }
    private(set) var isImporting = false {
        didSet { if !isAdoptingFromViews { environment.publishIsImporting(isImporting) } }
    }
    private(set) var importError: String? {
        didSet { if !isAdoptingFromViews { environment.publishError(importError) } }
    }

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: State written by the views

    /// The sheet binding (or a test) wrote the model's property. Keeps this copy in step without publishing it back,
    /// and without the cleanup `cancel()` does: a bare write of nil has never removed the extraction folder.
    func adoptReviewFromViews(_ value: SpokenMarginsPackageImportReview?) {
        guard value?.id != review?.id else { return }
        isAdoptingFromViews = true
        queue.replaceShowing(with: value)
        isAdoptingFromViews = false
    }

    func adoptIsImportingFromViews(_ value: Bool) {
        guard value != isImporting else { return }
        isAdoptingFromViews = true
        isImporting = value
        isAdoptingFromViews = false
    }

    func adoptErrorFromViews(_ value: String?) {
        guard value != importError else { return }
        isAdoptingFromViews = true
        importError = value
        isAdoptingFromViews = false
    }

    // MARK: Stage

    /// Copies the packet into its own folder under Application Support, verifies it and either opens an item it
    /// already belongs to or shows it for review. `releaseSource` runs once the packet no longer needs the file it
    /// came from: now for a packet already in the library, otherwise when its review is imported or cancelled. A
    /// rejected packet never calls it; the caller decides what happens to that file.
    func stage(
        from sourceURL: URL, announcesRejection: Bool = true, releaseSource: (@MainActor () -> Void)? = nil
    ) -> StageResult {
        var workingDirectory: URL?
        do {
            environment.bootstrapLibrary()
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let root = try environment.applicationSupportDirectory()
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
            let store = try environment.requireStore()
            let existing = try store.loadImportedCommentaryLayer(packageDigest: digest)
            let duplicateCheck = PackageImportPolicy.duplicateCheck(
                existing: existing,
                loadItem: { try? store.loadItem(id: $0) },
                hasValidItemAssociation: { layer, item in
                    SharedPacketItemMatcher.layerHasValidItemAssociation(layer, item: item,
                        ownedAudiobookDigest: environment.localAudiobookDigest(item))
                })
            if case .alreadyImported(let itemId) = duplicateCheck {
                environment.openItem(itemId)
                releaseSource?()
                if let item = try? store.loadItem(id: itemId), item.mediaType == "audiobook" {
                    restoringFolders.insert(root.lastPathComponent)
                    return .restoreAudio(RestoreAudio(item: item, contents: contents, directory: root))
                }
                if let localURL = environment.validatedLocalURL(itemId) {
                    environment.resolvePodcastCommentary(itemId, localURL)
                }
                environment.reportSuccess("These shared Margins are already in your library. Playback has not started.")
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "duplicate:\(digest)")
                try? FileManager.default.removeItem(at: root)
                return .staged
            }
            let staged = try makeReview(packageURL: copiedPackage, extractionDirectory: root, contents: contents,
                                        store: store, releaseSource: releaseSource)
            if review == nil { importError = nil }
            if case .waiting = queue.offer(staged) {
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "queued:\(digest)")
                environment.reportConfirmation(Self.waitingMessage)
                return .staged
            }
            environment.recordDiagnostic("lastSpokenMarginsPackageImport",
                duplicateCheck == .review(isRepair: true) ? "repair_previewed:\(digest)" : "previewed:\(digest)")
            return .staged
        } catch {
            if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "rejected:\(SharedMarginsImportMessage.diagnosticDetail(error))")
            // A kept file is tried again at launch; the caller says when the listener has already been told.
            if announcesRejection { environment.reportFailureMessage(SharedMarginsImportMessage.userFacing(error)) }
            return .rejected(needsNewerApp: (error as? SpokenMarginsPackageArchiveError)?.listenerOutcome == .needsNewerApp)
        }
    }

    /// The model's restore-audio task: places an already-imported listening package on the listener's audio.
    func restoreAudio(_ restore: RestoreAudio) async {
        defer { restoringFolders.remove(restore.directory.lastPathComponent) }
        do {
            try await placeOnOwnedAudio(
                restore.item, contents: restore.contents,
                admission: verifyLocalAudioForImport(restore.item, contents: restore.contents))
            environment.reportSuccess("Restored this listening package. Playback has not started.")
        } catch {
            environment.reportFailure(error, "Restoring listening package failed")
        }
    }

    // MARK: Launch sweep

    /// Removes the staged folders an app kill left behind (#2154): each launch reopens a packet that waits in the
    /// Share inbox into a fresh folder, so the one the killed run made would otherwise stay for good. It runs once,
    /// before the first stage of the run, and leaves any folder a review or restore here owns and any folder an
    /// imported layer or Margin names (those play from it). It opens the Library only when a folder is there to
    /// check, and tries again if the Library won't open.
    func sweepOrphanedFoldersOnce() {
        guard !didSweepOrphanedFolders, let support = try? environment.applicationSupportDirectory() else { return }
        let incoming = support.appending(path: "SpokenMargins/IncomingPackages", directoryHint: .isDirectory)
        let hasFolders = ((try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? [])
            .contains { UUID(uuidString: $0) != nil }
        // Nothing staged before: leave the Library closed, as it is on most launches.
        guard hasFolders else { didSweepOrphanedFolders = true; return }
        // Opening the store first would skip the root view's bootstrap, as in `stage`.
        environment.bootstrapLibrary()
        guard let store = try? environment.requireStore() else { return }
        didSweepOrphanedFolders = true
        let owned = Set(([queue.showing].compactMap { $0 } + queue.waiting).map { $0.extractionDirectory.lastPathComponent })
        let outcome = IncomingPackageSweep.sweep(directory: incoming, keeping: owned.union(restoringFolders), store: store)
        if !outcome.removed.isEmpty {
            environment.recordDiagnostic("lastIncomingPackageSweep", "removed:\(outcome.removed.count):kept:\(outcome.kept.count)")
        }
    }

    // MARK: Cancel and re-match

    func cancel() {
        guard !isImporting, let review else { return }
        queue.finish(review.id)
        importError = nil
        try? FileManager.default.removeItem(at: review.extractionDirectory)
        review.releaseSource?()
    }

    /// Reconciles a pending recipient-supplied package after Add Source returns.
    func refreshAfterAddingSource() {
        guard let review,
              review.requiresRecipientItem,
              !isImporting else { return }
        do {
            let store = try environment.requireStore()
            let refreshed = try makeReview(
                packageURL: review.packageURL, extractionDirectory: review.extractionDirectory,
                contents: review.contents, store: store, releaseSource: review.releaseSource
            )
            queue.replaceShowing(with: refreshed)
            if refreshed.matchingItemId == nil {
                importError = refreshed.isListeningMap
                    ? "That source does not match the item this map was made for yet. Add the same item or cancel."
                    : "That source does not match the item described by this package yet. Add the same item or cancel the import."
            } else {
                importError = nil
                environment.reportConfirmation(refreshed.isListeningMap
                    ? "Source matched. Review the shared map before adding it."
                    : "Source matched. Review the shared Margins before importing.")
            }
        } catch {
            importError = SharedMarginsImportMessage.userFacing(error)
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "source_reconciliation_failed:\(error.localizedDescription)")
        }
    }

    // MARK: Confirm

    /// The synchronous half of confirming, run before the model launches its task. Returns the review the task
    /// must import, or nil when there is nothing to do.
    func beginConfirmation() -> SpokenMarginsPackageImportReview? {
        guard let review, !isImporting else { return nil }
        guard !review.requiresRecipientItem else {
            importError = "This package does not include the item. Add the matching source, then return to this pending import."
            return nil
        }
        isImporting = true
        importError = nil
        return review
    }

    /// The model's confirm task body. `review` is the one `beginConfirmation()` returned. Success ends that review
    /// and brings up the next waiting one; failure annotates it only while it is still the one showing (#2122).
    func confirm(_ review: SpokenMarginsPackageImportReview) async {
        do {
            let store = try environment.requireStore()
            if ListeningMapPacket.isMapPacket(review.contents.manifest) {
                try await confirmListeningMap(review, store: store)
                return
            }
            let itemId: String?
            switch PackageImportPolicy.itemSource(
                matchingItemId: review.matchingItemId,
                transportKind: review.contents.manifest.itemTransport.kind,
                itemType: review.contents.manifest.item.itemType
            ) {
            case .existing(let matchingId):
                itemId = matchingId
            case .embeddedText:
                itemId = try installEmbeddedItem(from: review.contents, store: store)
            case .acquirePodcast:
                itemId = try await environment.acquirePodcast(review.contents.manifest.item)
            case .acquireArticle:
                itemId = try await environment.acquireArticle(review.contents.manifest.item)
            }
            let item = try itemId.map { try store.loadItem(id: $0) }
            let localItem = item.map {
                SharedPacketItemMatcher.localIdentity(for: $0, ownedAudiobookDigest: environment.localAudiobookDigest($0))
            }
            var localAudioAdmission: LocalAudioPacketAdmission?
            if let item, item.mediaType == "audiobook" {
                localAudioAdmission = try await verifyLocalAudioForImport(item, contents: review.contents)
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
                if let itemId { environment.recordDiagnostic("lastSpokenMarginsPackageRepair", "reassociated:\(existing.id):\(itemId)") }
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
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "duplicate_layer:\(existingLayerId)")
            case .imported(let layerId, let interjectionIds):
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "imported:\(layerId):\(interjectionIds.count)")
                environment.recordPacketImport(itemId, review.contents.manifest.packageId, interjectionIds.count)
            }
            if let itemId {
                try environment.showImportedItem(itemId, store)
                if let item,
                   item.media?.sourceType == .remoteStream,
                   let rawURL = item.media?.url,
                   let remoteURL = URL(string: rawURL) {
                    environment.registerRemoteDownload(itemId, remoteURL)
                }
                if let item, let localAudioAdmission {
                    try await placeOnOwnedAudio(item, contents: review.contents, admission: localAudioAdmission)
                } else if let localURL = environment.validatedLocalURL(itemId) {
                    environment.resolvePodcastCommentary(itemId, localURL)
                }
            }
            queue.finish(review.id)
            isImporting = false
            review.releaseSource?()
            environment.reportConfirmation("Imported shared Margins. Playback has not started.")
        } catch {
            isImporting = false
            if queue.isShowing(review.id) { importError = SharedMarginsImportMessage.userFacing(error) }
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "failed:\(error.localizedDescription)")
            environment.reportFailure(error, "Shared Margins import failed")
        }
    }

    // MARK: Local audio

    private func verifyLocalAudioForImport(_ item: Item, contents: VerifiedSpokenMarginsPackage) async throws -> LocalAudioPacketAdmission {
        guard let url = environment.ownedAudiobookURL(item) else {
            throw SpokenMarginsPackageArchiveError.invalidManifest("Local source audio is unavailable")
        }
        let actualDigest = try await Task.detached(priority: .utility) {
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: url)
        }.value
        return try LocalAudioPacketAdmission.admitted(
            contents,
            recipient: SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: environment.localAudiobookDigest(item)),
            itemId: item.id,
            actualDigest: actualDigest
        )
    }

    /// Exact maps project at the sender's times; a podcast packet on the listener's copy is placed like a download.
    private func placeOnOwnedAudio(_ item: Item, contents: VerifiedSpokenMarginsPackage, admission: LocalAudioPacketAdmission) async throws {
        if admission == .exactEdition { return try await activateImportedLocalAudioMaps(item: item, contents: contents) }
        if let url = environment.ownedAudiobookURL(item) { environment.resolvePodcastCommentary(item.id, url) }
    }

    private func activateImportedLocalAudioMaps(item: Item, contents: VerifiedSpokenMarginsPackage) async throws {
        let store = try environment.requireStore()
        let recipient = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: environment.localAudiobookDigest(item))
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
        if environment.selectedItemID() == item.id { environment.refreshSelectedItem() }
        environment.prepareLocalAudioBridges(item.id)
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
        let assetID = environment.summaryBridgeAssetID(itemId, proposalId, scene.id, suppliedID)
        let relativePath = "SpokenMargins/EpisodeMaps/\(PodcastAnchorEvidencePaths.safeComponent(itemId))/SummaryBridges/\(assetID).m4a"
        let support = try environment.applicationSupportDirectory()
        let destination = support.appending(path: relativePath)
        let ledger = environment.offlineLedger(store, support)
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

    // MARK: Items

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

    private func makeReview(
        packageURL: URL, extractionDirectory: URL, contents: VerifiedSpokenMarginsPackage, store: SQLiteSessionStore,
        releaseSource: (@MainActor () -> Void)?
    ) throws -> SpokenMarginsPackageImportReview {
        let matchingItemId = try matchingItemID(for: contents, store: store)
        var review = SpokenMarginsPackageImportReview(
            packageURL: packageURL, extractionDirectory: extractionDirectory,
            contents: contents, matchingItemId: matchingItemId
        )
        review.releaseSource = releaseSource
        if let matchingItemId, let proposal = ListeningMapPacket.proposal(in: contents) {
            review.replacesExistingMap = try SharedTextListeningMapImporter.existing(
                for: proposal, itemId: matchingItemId, repository: store
            ) == .differentMap
        }
        return review
    }

    private func matchingItemID(
        for contents: VerifiedSpokenMarginsPackage,
        store: SQLiteSessionStore
    ) throws -> String? {
        if environment.consumeForcedSourceMiss() {
            environment.recordDiagnostic("uiTestSharedSourceMiss", "forced_once")
            return nil
        }
        let items = try store.listItems()
        if let proposal = ListeningMapPacket.proposal(in: contents) {
            switch ListeningMapPacketItemMatcher.match(packetItem: contents.manifest.item, proposal: proposal, among: items) {
            case .item(let id): return id
            case .ambiguous:
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "map_source_ambiguous")
                return nil
            case .none: return nil
            }
        }
        return SharedPacketItemMatcher.matchingItemId(
            for: contents.manifest.item, among: items,
            ownedAudiobookDigest: { [environment] in environment.localAudiobookDigest($0) })
    }

    // MARK: Listening Map

    /// A shared Listening Map (#1471): finds or fetches the item, places the chapters on its text and saves them.
    /// No Margins are made and playback does not start.
    private func confirmListeningMap(_ review: SpokenMarginsPackageImportReview, store: SQLiteSessionStore) async throws {
        let manifest = review.contents.manifest
        let itemId: String
        if let matching = review.matchingItemId {
            itemId = matching
        } else {
            do {
                itemId = try await environment.acquireArticle(manifest.item)
            } catch let error as SessionKitError {
                if case .persistenceFailed("shared_article_unreadable") = error {
                    throw SessionKitError.persistenceFailed("shared_map_article_unreadable")
                }
                throw error
            }
        }
        let item = try store.loadItem(id: itemId)
        let contents = review.contents
        // Searching a long text for every chapter is slow, so it runs off the main actor; saving does not.
        let plan = try await Task.detached(priority: .userInitiated) {
            try SharedTextListeningMapImporter.plan(contents, for: item, repository: store)
        }.value
        var attach: ((ListeningMap) throws -> Void)?
        if let hook = environment.attachListeningMap { attach = { map in try hook(map) } }
        let outcome = try SharedTextListeningMapImporter.commit(
            plan, to: item, senderLabel: manifest.senderDisplayLabel, repository: store, attach: attach
        )
        switch outcome {
        case .alreadyAdded(let count):
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "duplicate_map:\(itemId):\(count)")
        case .added(let placed, let total, let replaced):
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "map_added:\(itemId):\(placed)/\(total):replaced=\(replaced)")
        }
        // The map is saved: from here the import has succeeded, whatever happens to the screen. A map packet
        // carries no assets, so its working copy can go now.
        queue.finish(review.id)
        isImporting = false
        try? FileManager.default.removeItem(at: review.extractionDirectory)
        review.releaseSource?()
        environment.reportConfirmation(outcome.message)
        do {
            try environment.showImportedItem(itemId, store)
        } catch {
            environment.reportFailure(error, "Opening the item after adding a Listening Map failed")
        }
    }
}
