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
        /// Names main-thread work for the hang probe. `stage` no longer has any (#2510).
        var labels = MainThreadOperationLabels()
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
    /// Folders `stage` has created and not yet handed to the queue, a restore or the bin. The sweep leaves them
    /// alone, so a stage that ever suspends between creating its folder and offering it cannot lose the folder
    /// to a sweep that listed it meanwhile.
    private var stagingFolders: Set<String> = []

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

    // MARK: Background staging

    /// Stages started from entry points that cannot wait (a system URL, a Add Source return), by id so a finished
    /// one drops out. Tests wait on them with `waitForStaging`.
    private var launched: [UUID: Task<Void, Never>] = [:]

    func launch(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        launched[id] = Task { @MainActor [weak self] in
            await work()
            self?.launched[id] = nil
        }
    }

    func waitForStaging() async {
        while let task = launched.values.first { await task.value; await Task.yield() }
    }

    func launchRefreshAfterAddingSource() {
        launch { [weak self] in await self?.refreshAfterAddingSource() }
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

    /// Creates `root`, copies the packet into it and reads the archive, on a background thread (#2510). The same
    /// steps in the same order as before; only the thread changes. The caller holds the security-scoped access to
    /// `sourceURL` for the whole call, and removes `root` itself if this throws.
    nonisolated private static func copyAndRead(from sourceURL: URL, into root: URL) async throws -> VerifiedSpokenMarginsPackage {
        try await Task.detached(priority: .userInitiated) {
            let copiedPackage = root.appending(path: "package.spokenmargins")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: copiedPackage)
            return try SpokenMarginsPackageArchive.read(
                from: copiedPackage,
                extractingAssetsTo: root.appending(path: "assets", directoryHint: .isDirectory)
            )
        }.value
    }

    /// Removes a staging folder on a background thread and returns when it is gone, so a rejected or duplicate packet
    /// leaves nothing behind by the time `stage` reports (#2510). It holds the same order as the main-thread delete did.
    nonisolated private static func removeFolder(_ url: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }

    /// Copies the packet into its own folder under Application Support, verifies it and either opens an item it
    /// already belongs to or shows it for review. `releaseSource` runs once the packet no longer needs the file it
    /// came from: now for a packet already in the library, otherwise when its review is imported or cancelled. A
    /// rejected packet never calls it; the caller decides what happens to that file.
    ///
    /// The Library is searched for the packet's item, and for an earlier import of it, off the main actor (#2507):
    /// matching hashes every item's text. The copy of the packet and the read of its archive run off the main actor
    /// too (#2510): both scale with the packet. The staging folder is registered in `stagingFolders` from its creation to the end of the call,
    /// so the launch sweep and a second `stage` that runs while this one waits leave it alone.
    func stage(
        from sourceURL: URL, announcesRejection: Bool = true, releaseSource: (@MainActor () -> Void)? = nil
    ) async -> StageResult {
        var workingDirectory: URL?
        do {
            environment.bootstrapLibrary()
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            let root = try environment.applicationSupportDirectory()
                .appending(path: "SpokenMargins/IncomingPackages/\(UUID().uuidString)", directoryHint: .isDirectory)
            workingDirectory = root
            stagingFolders.insert(root.lastPathComponent)
            defer { stagingFolders.remove(root.lastPathComponent) } // by then queue, restoringFolders or the bin owns it
            let copiedPackage = root.appending(path: "package.spokenmargins")
            let contents = try await Self.copyAndRead(from: sourceURL, into: root)
            guard let digest = contents.manifest.contentDigest else {
                throw SpokenMarginsPackageArchiveError.invalidDigest
            }
            let store = try environment.requireStore()
            let duplicate = try await lookUpDuplicate(digest: digest, store: store)
            let duplicateCheck = duplicate.check
            if case .alreadyImported(let itemId) = duplicateCheck {
                environment.openItem(itemId)
                releaseSource?()
                if let item = duplicate.item, item.mediaType == "audiobook" {
                    restoringFolders.insert(root.lastPathComponent)
                    return .restoreAudio(RestoreAudio(item: item, contents: contents, directory: root))
                }
                if let localURL = environment.validatedLocalURL(itemId) {
                    environment.resolvePodcastCommentary(itemId, localURL)
                }
                environment.reportSuccess("These shared Margins are already in your library. Playback has not started.")
                environment.recordDiagnostic("lastSpokenMarginsPackageImport", "duplicate:\(digest)")
                await Self.removeFolder(root) // the duplicate's copy and extracted assets, off the main actor (#2510)
                return .staged
            }
            let staged = try await makeReview(packageURL: copiedPackage, extractionDirectory: root, contents: contents,
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
            if let workingDirectory { await Self.removeFolder(workingDirectory) } // off the main actor (#2510)
            // The caller went away while the Library was searched (a replaced share link): nothing to tell the listener.
            if error is CancellationError { return .rejected(needsNewerApp: false) }
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
    ///
    /// The directory listing and the removals run on a background thread (#2507, #2510), so the call returns at
    /// once and a staged packet may be opened while it works. The sweep lists the folders first, and only those it
    /// listed are candidates; the folders a review or restore owns are read on the main actor after the listing,
    /// so a packet staged in the meantime is either in the listing and owned, or not in it and never touched.
    /// That is safe only because `stage` registers its folder in `stagingFolders` from the moment it creates it
    /// until the queue, a restore or the bin owns it, and the sweep keeps those too. `stage` is async since #2507, so
    /// it suspends between the two while the Library is searched; do not drop that set.
    func sweepOrphanedFoldersOnce() {
        guard !didSweepOrphanedFolders, sweepTask == nil,
              let support = try? environment.applicationSupportDirectory() else { return }
        let incoming = support.appending(path: "SpokenMargins/IncomingPackages", directoryHint: .isDirectory)
        sweepTask = Task { [weak self] in
            await self?.sweepOrphanedFolders(in: incoming)
            self?.sweepTask = nil
        }
    }

    /// The running sweep, so a test (or a caller that must not stage until it ends) can wait for it.
    private(set) var sweepTask: Task<Void, Never>?

    private func sweepOrphanedFolders(in incoming: URL) async {
        let listed = (try? await Gate1AppModel.offMain {
            ((try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []).filter { UUID(uuidString: $0) != nil }
        }) ?? []
        // Nothing staged before: leave the Library closed, as it is on most launches.
        guard !listed.isEmpty else { didSweepOrphanedFolders = true; return }
        // Opening the store first would skip the root view's bootstrap, as in `stage`.
        environment.bootstrapLibrary()
        guard let store = try? environment.requireStore() else { return }
        didSweepOrphanedFolders = true
        let owned = Set(([queue.showing].compactMap { $0 } + queue.waiting).map { $0.extractionDirectory.lastPathComponent })
        let keeping = owned.union(restoringFolders).union(stagingFolders)
        let candidates = Set(listed)
        let outcome = try? await Gate1AppModel.offMain {
            IncomingPackageSweep.sweep(directory: incoming, keeping: keeping, only: candidates, store: store)
        }
        if let outcome, !outcome.removed.isEmpty {
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

    /// Reconciles a pending recipient-supplied package after Add Source returns. The search runs off the main
    /// actor; if the review was cancelled, replaced or started importing meanwhile, the answer is dropped.
    func refreshAfterAddingSource() async {
        guard let review,
              review.requiresRecipientItem,
              !isImporting else { return }
        do {
            let store = try environment.requireStore()
            let refreshed = try await makeReview(
                packageURL: review.packageURL, extractionDirectory: review.extractionDirectory,
                contents: review.contents, store: store, releaseSource: review.releaseSource
            )
            guard queue.isShowing(review.id), !isImporting else { return }
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
            guard queue.isShowing(review.id) else { return }
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
                itemId = try await installEmbeddedItem(from: review.contents, store: store)
            case .acquirePodcast:
                itemId = try await environment.acquirePodcast(review.contents.manifest.item)
            case .acquireArticle:
                itemId = try await environment.acquireArticle(review.contents.manifest.item)
            }
            // The item, the duplicate check and the import commit run on a background thread (#2509). `isImporting`
            // already keeps a second confirm, a cancel and a re-match out until this ends, so nothing else writes
            // meanwhile; the writes keep their order inside one step.
            let reader = StoreReader(store)
            let item: Item? = if let itemId { try await reader.read { try $0.loadItem(id: itemId) } } else { nil }
            let ownedAudiobookDigest = item.flatMap { environment.localAudiobookDigest($0) }
            var localAudioAdmission: LocalAudioPacketAdmission?
            if let item, item.mediaType == "audiobook" {
                localAudioAdmission = try await verifyLocalAudioForImport(item, contents: review.contents)
            }
            let itemText = item?.text
            let contents = review.contents
            let (disposition, repairedLayerId) = try await reader.read { store -> (ImportedCommentaryImportDisposition, String?) in
                let localItem = item.map {
                    SharedPacketItemMatcher.localIdentity(for: $0, ownedAudiobookDigest: ownedAudiobookDigest)
                }
                if let digest = contents.manifest.contentDigest,
                   let existing = try store.loadImportedCommentaryLayer(packageDigest: digest) {
                    try SpokenMarginsPackageImporter.repairAssociation(
                        existing: existing,
                        contents: contents,
                        itemId: itemId,
                        localItem: localItem,
                        itemText: itemText,
                        repository: store
                    )
                    return (.duplicate(existingLayerId: existing.id), existing.id)
                }
                return (try SpokenMarginsPackageImporter.importPackage(
                    contents,
                    itemId: itemId,
                    localItem: localItem,
                    itemText: itemText,
                    repository: store
                ), nil)
            }
            if let repairedLayerId, let itemId {
                environment.recordDiagnostic("lastSpokenMarginsPackageRepair", "reassociated:\(repairedLayerId):\(itemId)")
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
            // Both rows go in one background step, in this order (#2509).
            try await StoreReader(store).read {
                try $0.savePortableListeningMapProposal(proposal, itemId: item.id)
                try $0.saveResolvedListeningMapProjection(projection)
            }
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
    ) async throws -> String {
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
        try await StoreReader(store).read { try $0.seed(item: item) } // off the main actor (#2509)
        return itemID
    }

    private func makeReview(
        packageURL: URL, extractionDirectory: URL, contents: VerifiedSpokenMarginsPackage, store: SQLiteSessionStore,
        releaseSource: (@MainActor () -> Void)?
    ) async throws -> SpokenMarginsPackageImportReview {
        let found = try await lookUpSourceMatch(for: contents, store: store)
        var review = SpokenMarginsPackageImportReview(
            packageURL: packageURL, extractionDirectory: extractionDirectory,
            contents: contents, matchingItemId: found.itemId
        )
        review.releaseSource = releaseSource
        review.replacesExistingMap = found.replacesExistingMap
        return review
    }

    /// Whether an earlier import of this packet still stands, read off the main actor with the item it stands on.
    private func lookUpDuplicate(digest: String, store: SQLiteSessionStore) async throws -> PackageDuplicateLookup {
        try await StoreReader(store).read { store in
            let existing = try store.loadImportedCommentaryLayer(packageDigest: digest)
            let check = PackageImportPolicy.duplicateCheck(
                existing: existing,
                loadItem: { try? store.loadItem(id: $0) },
                hasValidItemAssociation: { layer, item in
                    SharedPacketItemMatcher.layerHasValidItemAssociation(layer, item: item,
                        ownedAudiobookDigest: Self.ownedAudiobookDigest(for: item, store: store))
                })
            guard case .alreadyImported(let itemId) = check else { return PackageDuplicateLookup(check: check, item: nil) }
            return PackageDuplicateLookup(check: check, item: try? store.loadItem(id: itemId))
        }
    }

    /// The Library item a packet is about, and whether a map packet would replace the map that item has. Matching
    /// runs off the main actor (#2507), and reads each item without its text: the digests of the text the packet is
    /// compared by are kept beside the item, and hashed once for an item that has none yet (#2506). Only a PDF or EPUB
    /// map packet that no item's identity names reads the documents whole, to place its chapters on their text.
    private func lookUpSourceMatch(
        for contents: VerifiedSpokenMarginsPackage,
        store: SQLiteSessionStore
    ) async throws -> PackageSourceMatch {
        if environment.consumeForcedSourceMiss() {
            environment.recordDiagnostic("uiTestSharedSourceMiss", "forced_once")
            return PackageSourceMatch()
        }
        let found = try await StoreReader(store).read { store -> PackageSourceMatch in
            let rows = try store.listItemsForMatching(
                format: PortableArticleAnchorResolver.itemTextDigestFormat,
                needsDigests: SharedItemIdentityBuilder.isMatchedByItsText,
                digests: PortableArticleAnchorResolver.itemTextDigests)
            let items = rows.map(\.item)
            let digestsById = Dictionary(rows.compactMap { row in row.textDigests.map { (row.item.id, $0) } },
                                         uniquingKeysWith: { first, _ in first })
            guard let proposal = ListeningMapPacket.proposal(in: contents) else {
                return PackageSourceMatch(itemId: SharedPacketItemMatcher.matchingItemId(
                    for: contents.manifest.item, among: items,
                    ownedAudiobookDigest: { Self.ownedAudiobookDigest(for: $0, store: store) },
                    textDigests: { digestsById[$0.id] }))
            }
            let packetItem = contents.manifest.item
            let match: ListeningMapPacketItemMatcher.Match
            if let id = ListeningMapPacketItemMatcher.identityMatch(
                packetItem: packetItem, among: items, textDigests: { digestsById[$0.id] }) {
                match = .item(id)
            } else if packetItem.itemType == .pdf || packetItem.itemType == .epub {
                match = ListeningMapPacketItemMatcher.match(packetItem: packetItem, proposal: proposal, among: try store.listItems())
            } else {
                match = .none
            }
            switch match {
            case .item(let id):
                let replaces = try SharedTextListeningMapImporter.existing(
                    for: proposal, itemId: id, repository: store
                ) == .differentMap
                return PackageSourceMatch(itemId: id, replacesExistingMap: replaces)
            case .ambiguous:
                return PackageSourceMatch(mapSourceAmbiguous: true)
            case .none:
                return PackageSourceMatch()
            }
        }
        if found.mapSourceAmbiguous {
            environment.recordDiagnostic("lastSpokenMarginsPackageImport", "map_source_ambiguous")
        }
        return found
    }

    /// The same answer as `Gate1AppModel.localAudiobookDigest(for:)`, for code that already runs off the main actor.
    private nonisolated static func ownedAudiobookDigest(for item: Item, store: SQLiteSessionStore) -> String? {
        item.mediaType == "audiobook"
            ? SharedPacketItemMatcher.ownedAudiobookDigest(for: item, assets: (try? store.loadOwnedOfflineAssets(itemId: item.id)) ?? [])
            : nil
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
        let item = try await StoreReader(store).read { try $0.loadItem(id: itemId) }
        let contents = review.contents
        // Searching a long text for every chapter is slow, so it runs off the main actor; saving does not.
        let plan = try await Task.detached(priority: .userInitiated) {
            try SharedTextListeningMapImporter.plan(contents, for: item, repository: store)
        }.value
        // The map goes to a running session on the main actor, which may refuse it (a map can't change under
        // playback) before anything is saved. The proposal rows are written on a background thread (#2509); with no
        // session to tell, the map and the proposal go in one background step, in the order `commit` writes them.
        let senderLabel = manifest.senderDisplayLabel
        let outcome: SharedTextListeningMapImporter.Outcome
        if let map = SharedTextListeningMapImporter.mapToAttach(plan, to: item, senderLabel: senderLabel) {
            if let hook = environment.attachListeningMap {
                try hook(map)
                outcome = try await StoreReader(store).read { try SharedTextListeningMapImporter.saveProposal(plan, to: item, repository: $0) }
            } else {
                outcome = try await StoreReader(store).read {
                    try $0.saveListeningMap(map)
                    return try SharedTextListeningMapImporter.saveProposal(plan, to: item, repository: $0)
                }
            }
        } else {
            outcome = SharedTextListeningMapImporter.outcome(of: plan) // already added: nothing to write
        }
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

private struct PackageDuplicateLookup: Sendable {
    let check: PackageImportPolicy.DuplicateCheck
    /// The item an `alreadyImported` check stands on; nil otherwise or when it no longer loads.
    let item: Item?
}

private struct PackageSourceMatch: Sendable {
    var itemId: String?
    /// A map packet that two files hold equally well: the listener is asked, so no item is chosen.
    var mapSourceAmbiguous = false
    var replacesExistingMap = false
}
