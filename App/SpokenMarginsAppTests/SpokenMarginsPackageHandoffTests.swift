import XCTest
import AVFoundation
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

final class SpokenMarginsPackageHandoffTests: XCTestCase {
    func testRealRecipientWindowExportKeepsMeasuredSourceBoundsAtMiddleAndEpisodeEnd() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-real-window-export")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recipient.wav")
        try writeSilentRecipientAudio(to: source)
        let itemID = "real-window-\(UUID().uuidString)"
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let windowRoot = caches.appending(path: "SourceAudioTranscriptionWindows/\(itemID)")
        defer { try? FileManager.default.removeItem(at: windowRoot) }
        let client = SystemSourceTranscriptionClient()

        for (anchor, before, after, expectedStart, expectedEnd) in [
            (15_000, 5_000, 5_000, 10_000, 20_000),
            (299_000, 2_000, 4_000, 297_000, 300_000)
        ] {
            let window = try await client.acquireSourceAudioWindow(
                url: source, itemId: itemID, anchorMediaTimeMs: anchor,
                durationMs: 300_000, windowBeforeMs: before, windowAfterMs: after)
            let bytes = try Data(contentsOf: window.localAudioURL)
            XCTAssertFalse(bytes.isEmpty)
            XCTAssertEqual(window.provenance, .downloadedSourceReference)
            XCTAssertGreaterThanOrEqual(window.sourceStartMs, expectedStart)
            XCTAssertLessThanOrEqual(window.sourceStartMs, expectedStart + 100)
            XCTAssertGreaterThanOrEqual(window.sourceEndMs, expectedEnd - 100)
            XCTAssertLessThanOrEqual(window.sourceEndMs, expectedEnd)
        }
    }

    func testPackageHandoffPreservesExactBytesUntilConsumed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Shared Session.spokenmargins")
        let expected = Data([0x50, 0x4b, 0x03, 0x04, 0x00, 0xff, 0x10])
        try expected.write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        let payloadID = try store.savePackage(from: source)

        XCTAssertEqual(try store.pendingPayloadIDs(), [payloadID])
        XCTAssertEqual(try Data(contentsOf: store.packageURL(payloadID: payloadID)), expected)
        try store.deletePackage(payloadID: payloadID)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty)
    }

    func testPackageHandoffRejectsAFileWithoutTheOwnedExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-handoff-rejection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: source)
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)

        XCTAssertThrowsError(try store.savePackage(from: source)) { error in
            XCTAssertEqual(
                error as? SpokenMarginsPackageHandoffStoreError,
                .invalidPackage("the file extension is not .spokenmargins")
            )
        }
    }

    @MainActor
    func testSystemShareDeclaresTheOwnedPackageType() {
        let url = URL(fileURLWithPath: "/tmp/shared-session.spokenmargins")
        let item = SpokenMarginsPackageActivityItem(packageURL: url)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)

        XCTAssertEqual(
            item.activityViewController(controller, dataTypeIdentifierForActivityType: nil),
            SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: nil) as? URL,
            url
        )
    }

    @MainActor
    func testAppConsumesShareExtensionPackageIntoRecipientImportFlow() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-package-handoff",
            itemId: itemID,
            sessionId: "session-package-handoff",
            targetType: .item,
            targetId: itemID,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 25,
            anchor: Anchor(
                anchorType: .text,
                startChar: 0,
                endChar: 5,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "A shared Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        try model.persistSelectedInterjectionsForSharingTests()
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let packageURL = try XCTUnwrap(coordinator.verifiedShareFileURL)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spoken-margins-package-consumption-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SpokenMarginsPackageHandoffStore(baseDirectory: root)
        _ = try store.savePackage(from: packageURL)

        try model.consumePendingSpokenMarginsPackageHandoffs(from: store)

        XCTAssertNotNil(model.spokenMarginsPackageImportReview)
        XCTAssertTrue(try store.pendingPayloadIDs().isEmpty)
        XCTAssertTrue(model.diagnostics.values.contains("opened"))
        model.cancelSpokenMarginsPackageImport()
    }

    @MainActor
    func testPodcastPackageImportBindsToImportedItemInsteadOfStaleSelection() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-podcast-binding")
        // Background model work can retain SQLite; let the process close it before cleanup.
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("different-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-different-episode")
        // Opening a store migrates/writes metadata. Prepare the inspection connection
        // before asynchronous model work, then read the actual persisted import below.
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let previouslySelectedItemID = model.selectedItem.id

        model.handleIncomingURL(packageURL)

        XCTAssertEqual(model.spokenMarginsPackageImportReview?.contents.manifest.item.title, Self.podcastTitle)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let importedItem = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertNotEqual(importedItem.id, previouslySelectedItemID)
        XCTAssertEqual(layer.itemId, importedItem.id)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(model.selectedItem.title, Self.podcastTitle)
        XCTAssertEqual(model.screen, .item)
        XCTAssertNil(model.snapshot.sessionId, "Import must not start playback")

        model.handleIncomingURL(packageURL)

        XCTAssertNil(model.spokenMarginsPackageImportReview)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)

        model.moveItemToTrash(id: importedItem.id)
        XCTAssertFalse(model.libraryItems.contains(where: { $0.id == importedItem.id }))
        model.handleIncomingURL(packageURL)
        XCTAssertNotNil(model.spokenMarginsPackageImportReview, "Reopening must restore a deleted target instead of routing elsewhere")
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        XCTAssertTrue(model.libraryItems.contains(where: { $0.id == importedItem.id }))
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(
            try store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest))?.itemId,
            importedItem.id
        )

        model.startItem(id: importedItem.id)
        XCTAssertEqual(model.snapshot.itemId, importedItem.id)
    }

    @MainActor
    func testPodcastPackageCreatesReferencedEpisodeWithoutPublisherPageFetch() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-offline-publisher-page")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("referenced-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-reference-with-enclosure")
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let model = Gate1AppModel(
            sourceLinkResolver: FailingPackagePodcastLinkResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()

        model.handleIncomingURL(packageURL)
        XCTAssertNil(model.spokenMarginsPackageImportReview?.matchingItemId)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let imported = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let item = try store.loadItem(id: imported.id)
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: try XCTUnwrap(manifest.contentDigest)))
        XCTAssertEqual(item.externalReference, Self.podcastURL)
        XCTAssertEqual(item.media?.url, Self.podcastAudioURL)
        XCTAssertEqual(layer.itemId, item.id)
        XCTAssertNotEqual(layer.sourceResolutionStatus, .wrongSource)
        XCTAssertNil(model.spokenMarginsPackageImportError)
        XCTAssertEqual(model.diagnostics["lastSharedPodcastAcquisition"], "package_reference_after_resolution_failure")
    }

    @MainActor
    func testReopeningCorruptedWrongSourcePackageRepairsItsItemAssociation() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-package-repair")
        // Background model work can retain SQLite; let the process close it before cleanup.
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("repair-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-repair-episode")
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        let wrongItemID = model.selectedItem.id
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let extracted = root.appendingPathComponent("corrupt-import-assets", isDirectory: true)
        let contents = try SpokenMarginsPackageArchive.read(from: packageURL, extractingAssetsTo: extracted)
        _ = try SpokenMarginsPackageImporter.importPackage(
            contents,
            itemId: wrongItemID,
            localItem: SharedItemIdentity(
                itemType: .text,
                canonicalURL: "https://example.com/wrong-item",
                title: "Wrong item"
            ),
            itemText: "Wrong item text",
            repository: store
        )
        let digest = try XCTUnwrap(manifest.contentDigest)
        XCTAssertEqual(try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus, .wrongSource)

        model.handleIncomingURL(packageURL)

        XCTAssertNotNil(model.spokenMarginsPackageImportReview)
        XCTAssertTrue(model.diagnostics["lastSpokenMarginsPackageImport"]?.hasPrefix("repair_previewed:") == true)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let importedItem = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let repairedLayer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        XCTAssertNotEqual(repairedLayer.itemId, wrongItemID)
        XCTAssertEqual(repairedLayer.itemId, importedItem.id)
        XCTAssertNotEqual(repairedLayer.sourceResolutionStatus, .wrongSource)
        XCTAssertEqual(model.selectedItem.id, importedItem.id)
        XCTAssertEqual(model.diagnostics["lastSpokenMarginsPackageRepair"], "reassociated:\(repairedLayer.id):\(importedItem.id)")
    }

    func testImportedAssetPathRebasesAfterApplicationContainerRelocation() throws {
        let root = try temporaryDirectory(named: "spoken-margins-relocated-assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let relativePath = "SpokenMargins/IncomingPackages/package/assets/margin.m4a"
        let relocated = support.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: relocated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("voice".utf8).write(to: relocated)
        let stalePath = "/old/container/Library/Application Support/\(relativePath)"

        XCTAssertEqual(
            Gate1AppModel.resolvedApplicationSupportAssetURL(
                for: stalePath,
                applicationSupportDirectory: support
            ),
            relocated
        )
        XCTAssertEqual(
            Gate1AppModel.resolvedInterjectionAudioURL(
                for: stalePath,
                applicationSupportDirectory: support
            ),
            relocated,
            "The imported Margin voice player must use the relocated file, not the stale container path."
        )
        XCTAssertNil(Gate1AppModel.resolvedInterjectionAudioURL(
            for: "/old/container/Library/Application Support/SpokenMargins/IncomingPackages/package/assets/missing.m4a",
            applicationSupportDirectory: support
        ))
    }

    func testWeakerPodcastEvidenceRetainsPositionOnlyForSameKnownAudioEdition() throws {
        let previous = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)
        let absent = ImportedAnchorResolution(evidenceClass: .unresolved)
        for (old, current) in [("old", "new"), (nil, "new"), (nil, nil)] as [(String?, String?)] {
            let result = Gate1AppModel.podcastResolution(previous: previous, proposed: absent,
                previousEdition: old, currentEdition: current, hasTranscript: false)
            XCTAssertEqual(result.evidenceClass, .unresolved)
            XCTAssertNil(result.localMediaTimeMs)
        }
        XCTAssertEqual(Gate1AppModel.podcastResolution(previous: previous, proposed: absent,
            previousEdition: "same", currentEdition: "same", hasTranscript: false), previous)
        let moved = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 65_000)
        XCTAssertEqual(Gate1AppModel.podcastResolution(previous: previous, proposed: moved,
            previousEdition: "old", currentEdition: "new", hasTranscript: true), moved)
    }

    func testRecipientTranscriptRejectsSameURLAfterAudioBytesChange() throws {
        let root = try temporaryDirectory(named: "recipient-edition-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("episode.m4a")
        try Data("first audio edition".utf8).write(to: source)
        let transcriptEdition = try Gate1AppModel.verifiedRecipientEditionDigest(at: source, expected: nil)
        XCTAssertEqual(
            try Gate1AppModel.verifiedRecipientEditionDigest(at: source, expected: transcriptEdition),
            transcriptEdition
        )

        try Data("replacement audio edition".utf8).write(to: source, options: .atomic)
        XCTAssertThrowsError(try Gate1AppModel.verifiedRecipientEditionDigest(
            at: source, expected: transcriptEdition
        )) { error in
            XCTAssertTrue(String(describing: error).contains("recipient_transcript_edition_changed"))
        }
    }

    func testReplacingRecipientEditionInvalidatesDurablePlacementsAndProjection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "package-digest",
            packageId: "package", itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(), sourceResolutionStatus: .resolved, isEnabled: true,
            resolvedRecipientEditionSHA256: "old")
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(id: "note", layerId: layer.id,
            packageScopedId: "note", createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .media),
            approvedTranscript: "Preserve my words", resolution: ImportedAnchorResolution(
                evidenceClass: .acousticVerified, localMediaTimeMs: 45_000)))
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(id: "projection", itemId: "item",
            recipientEditionSHA256: "old", algorithmVersion: "episode-projection.exact-edition.v1", points: [], intervals: []))
        try Gate1AppModel.invalidatePodcastEdition(itemId: "item", digest: "old", store: store)
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: layer.id).first?.resolution.localMediaTimeMs, 45_000)
        try Gate1AppModel.invalidatePodcastEdition(itemId: "item", digest: "new", store: store)
        let reopened = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let note = try XCTUnwrap(reopened.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(note.approvedTranscript, "Preserve my words")
        XCTAssertNil(note.resolution.localMediaTimeMs)
        XCTAssertEqual(note.resolution.evidenceClass, .unresolved)
        XCTAssertEqual(try reopened.loadImportedCommentaryLayers(itemId: "item").first?.sourceResolutionStatus, .pending)
        XCTAssertNil(try reopened.loadResolvedListeningMapProjection(itemId: "item")?.projectedRecipientTime(for: 45_000))
        let encoded = try JSONEncoder().encode(layer)
        XCTAssertEqual(try JSONDecoder().decode(ImportedCommentaryLayer.self, from: encoded).resolvedRecipientEditionSHA256, "old")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "resolvedRecipientEditionSHA256")
        XCTAssertNil(try JSONDecoder().decode(ImportedCommentaryLayer.self, from: JSONSerialization.data(withJSONObject: legacy)).resolvedRecipientEditionSHA256)
    }

    func testMixedImportedLayerKeepsItsVerifiedMarginsPlaybackEligible() {
        let layer = ImportedCommentaryLayer(
            id: "layer",
            itemId: "item",
            packageDigest: "digest",
            packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
            importedAt: Date(),
            sourceResolutionStatus: .ambiguous,
            isEnabled: true
        )
        let resolved = ImportedCommentaryInterjection(
            id: "resolved",
            layerId: layer.id,
            packageScopedId: "margin-1",
            createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1_000),
            approvedTranscript: "Resolved",
            resolution: ImportedAnchorResolution(
                evidenceClass: .acousticVerified,
                localMediaTimeMs: 1_050,
                confidence: 0.9
            )
        )
        let absent = ImportedCommentaryInterjection(
            id: "absent",
            layerId: layer.id,
            packageScopedId: "margin-2",
            createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 2_000),
            approvedTranscript: "Absent",
            resolution: ImportedAnchorResolution(evidenceClass: .absentFromRecipientEdition)
        )

        XCTAssertTrue(Gate1AppModel.isImportedCommentaryLayerPlaybackEligible(
            layer,
            records: [resolved, absent]
        ))
        XCTAssertFalse(Gate1AppModel.isImportedCommentaryLayerPlaybackEligible(
            layer,
            records: [absent]
        ))
    }

    @MainActor
    func testImportedPodcastRequestsTranscriptFallbackAndResolvesFuzzyContext() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-transcript-fallback")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("transcript-fallback.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-transcript-fallback")
        let transcriber = PackageAnchorTranscriptionClient()
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let item = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let localURL = root.appendingPathComponent("recipient.wav")
        try writeSilentRecipientAudio(to: localURL)
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            // Startup work may outlive this case. Never unlink an open SQLite/WAL
            // file; any retained UUID fixture remains in the test host's temp area.
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        let digest = try XCTUnwrap(manifest.contentDigest)
        let importedLayer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        let importedMargin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: importedLayer.id).first)
        XCTAssertTrue(PodcastTranscriptAnchorResolver.hasUsableContext(importedMargin.anchorEvidence))
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        for _ in 0..<250 {
            if await transcriber.windowRequestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fullRequestCount = await transcriber.fullRequestCount()
        let initialWindowCount = await transcriber.windowRequestCount()
        XCTAssertEqual(fullRequestCount, 0)
        XCTAssertGreaterThan(initialWindowCount, 0)
        let transcriptJobID = await transcriber.lastRequestedItemID()
        XCTAssertTrue(transcriptJobID?.hasPrefix("recipient-") == true)
        XCTAssertNotEqual(transcriptJobID, item.id)

        for _ in 0..<250 {
            if try store.loadImportedCommentaryLayer(packageDigest: digest)?.sourceResolutionStatus == .resolved {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        let margin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(model.diagnostics["sourceTranscriptionAfterDownload:\(item.id)"], "requested_for_imported_commentary")
        XCTAssertEqual(layer.sourceResolutionStatus, .resolved)
        XCTAssertEqual(margin.resolution.evidenceClass, .transcriptVerified)
        XCTAssertEqual(margin.resolution.localMediaTimeMs, 5_500)
        let completedWindowCount = await transcriber.windowRequestCount()
        XCTAssertGreaterThan(completedWindowCount, 1)
        XCTAssertNil(try store.loadTranscriptTimeline(itemId: item.id))
        XCTAssertEqual(model.diagnostics["recipientAlignmentTranscript:\(item.id)"], "complete_audio_deleted")
    }

    @MainActor
    func testRecipientRecoveryResumesOnlyUnfinishedWindowsAfterBootstrap() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-recipient-resume")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("recipient-resume.spokenmargins")
        _ = try writePodcastPackage(to: packageURL, packageID: "package-recipient-resume")
        let original = Gate1AppModel(
            sourceLinkResolver: podcastResolver(), audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: databaseURL)
        original.resetAndSeed()
        original.handleIncomingURL(packageURL)
        original.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(original)
        let item = try XCTUnwrap(original.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let localURL = root.appendingPathComponent("recipient.wav")
        try writeSilentRecipientAudio(to: localURL)
        let duration = try await Gate1AppModel.recipientSourceDurationMs(at: localURL)
        let digest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
        let store = try original.libraryStoreForTesting()
        var job = RecipientTranscriptRecoveryJob(
            itemId: item.id, editionSHA256: digest, durationMs: duration,
            localSourcePath: localURL.path,
            windows: [.init(startMs: 0, endMs: 1_000), .init(startMs: 1_000, endMs: duration)])
        job.windows[0].timeline = TranscriptTimeline(segments: [], chapters: [], durationMs: duration)
        try store.saveRecipientTranscriptRecoveryJob(job)

        let transcriber = PackageAnchorTranscriptionClient()
        let resumed = Gate1AppModel(
            sourceLinkResolver: podcastResolver(), audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber, databaseURLOverride: databaseURL)
        resumed.bootstrapLibraryIfNeeded()
        for _ in 0..<250 {
            if try store.loadRecipientTranscriptRecoveryJob(itemId: item.id)?.status == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let completed = try XCTUnwrap(store.loadRecipientTranscriptRecoveryJob(itemId: item.id))
        XCTAssertEqual(completed.id, job.id)
        XCTAssertEqual(completed.status, .complete)
        XCTAssertEqual(completed.windows[0], job.windows[0])
        let requests = await transcriber.windowRequestCount()
        XCTAssertEqual(requests, 1, "The persisted first window must not be transcribed again")
        let fullRequests = await transcriber.fullRequestCount()
        XCTAssertEqual(fullRequests, 0)
        addTeardownBlock { [weak original, weak resumed, weak store] in
            if original == nil, resumed == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    @MainActor
    func testReplacementReadyDuringRecipientSweepStartsNewEditionAfterOldWindow() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-recipient-replacement")
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("recipient-replacement.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-recipient-replacement")
        let transcriber = PackageAnchorTranscriptionClient(paused: true)
        let model = Gate1AppModel(
            sourceLinkResolver: podcastResolver(),
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            databaseURLOverride: databaseURL
        )
        model.resetAndSeed()
        model.handleIncomingURL(packageURL)
        model.confirmSpokenMarginsPackageImport()
        try await waitForImportToFinish(model)

        let item = try XCTUnwrap(model.libraryItems.first(where: { $0.title == Self.podcastTitle }))
        let localURL = root.appendingPathComponent("recipient.wav")
        try writeSilentRecipientAudio(to: localURL)
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            if model == nil, store == nil {
                try FileManager.default.removeItem(at: root)
            }
        }
        let packageDigest = try XCTUnwrap(manifest.contentDigest)
        let oldDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        for _ in 0..<250 {
            if await transcriber.windowRequestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let requestCount = await transcriber.windowRequestCount()
        XCTAssertEqual(requestCount, 1)
        let replacementURL = root.appendingPathComponent("replacement.wav")
        try writeSilentRecipientAudio(to: replacementURL, firstSample: 0.25)
        try FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: replacementURL, to: localURL)
        let newDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
        XCTAssertNotEqual(newDigest, oldDigest)
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        await transcriber.release()

        for _ in 0..<250 {
            if await transcriber.windowRequestCount() > 1,
               try store.loadImportedCommentaryLayer(packageDigest: packageDigest)?.sourceResolutionStatus == .resolved {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let layer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: packageDigest))
        let margin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first)
        XCTAssertEqual(layer.sourceResolutionStatus, .resolved)
        XCTAssertEqual(layer.resolvedRecipientEditionSHA256, newDigest)
        XCTAssertEqual(margin.resolution.evidenceClass, .transcriptVerified)
        let finalWindowCount = await transcriber.windowRequestCount()
        XCTAssertGreaterThan(finalWindowCount, 1)
    }

    private static let podcastTitle = "Can you spot the imported story?"
    private static let podcastURL = "https://podcasts.example.com/episodes/imported-story"
    private static let podcastAudioURL = "https://cdn.example.com/imported-story.mp3"

    private func podcastResolver() -> PackagePodcastLinkResolver {
        PackagePodcastLinkResolver(result: LinkResolutionResult(
            requestId: "ignored",
            status: .playable,
            originalLink: SourceLink(url: Self.podcastURL, provider: "podcast", role: "discovery"),
            selectedCandidate: LinkResolutionCandidate(
                sourceLink: SourceLink(url: "https://podcasts.example.com/feed.xml", provider: "rss", role: "canonical_feed"),
                title: Self.podcastTitle,
                durationMs: 300_000,
                audioURL: Self.podcastAudioURL,
                confidence: 1
            )
        ))
    }

    private func writePodcastPackage(
        to url: URL,
        packageID: String
    ) throws -> SpokenMarginsPackageManifest {
        let revision = InterjectionShareRevision(
            id: "revision-\(packageID)",
            interjectionId: "sender-margin",
            itemId: "sender-item",
            sessionId: "sender-session",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            approvedTranscript: "A sender-reviewed observation.",
            anchorBefore: "the durable prefix has exactly enough unique words here",
            anchorAfter: "the following suffix is also uniquely present right now",
            status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageID,
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            item: SharedItemIdentity(
                itemType: .podcast,
                canonicalURL: Self.podcastURL,
                originalURL: Self.podcastURL,
                title: Self.podcastTitle,
                enclosureURL: Self.podcastAudioURL,
                durationMs: 300_000
            ),
            itemTransportSelection: .reference,
            selections: [ReviewedInterjectionSelection(
                packageScopedId: "margin-001",
                revision: revision,
                anchor: PortableAnchorEvidence(
                    anchorType: .transcript,
                    prefix: "the durable prefix has exactly enough unique words here",
                    suffix: "the following suffix is also uniquely present right now",
                    mediaTimeMs: 5_000
                ),
                representation: .textOnly
            )],
            senderDisplayLabel: "Cole",
            suggestedRevealMode: .companion
        )
        return try SpokenMarginsPackageArchive.write(prepared, to: url)
    }

    private func temporaryDirectory(named prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSilentRecipientAudio(to url: URL, firstSample: Float = 0) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        second.frameLength = 8_000
        second.floatChannelData?[0][0] = firstSample
        for _ in 0..<300 { try file.write(from: second) }
    }

    @MainActor
    private func waitForImportToFinish(_ model: Gate1AppModel) async throws {
        for _ in 0..<250 {
            if model.spokenMarginsPackageImportReview == nil, !model.isImportingSpokenMarginsPackage {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the package import to finish: \(model.spokenMarginsPackageImportError ?? "no error")")
        throw SessionKitError.persistenceFailed("package_import_test_timeout")
    }
}

private actor PackageAnchorTranscriptionClient: SourceTranscriptionClient {
    private var fullRequests = 0
    private var windowRequests = 0
    private var requestedItemID: String?
    private var paused: Bool
    private var pendingCompletion: CheckedContinuation<Void, Never>?

    init(paused: Bool = false) {
        self.paused = paused
    }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        fullRequests += 1
        throw SessionKitError.persistenceFailed("full_source_transcription_must_not_run")
    }

    func transcribeSourceAudioWindowWithEvidence(
        url: URL, itemId: String, anchorMediaTimeMs: Int, durationMs: Int?,
        windowBeforeMs: Int, windowAfterMs: Int
    ) async throws -> SourceAudioWindowTranscription {
        windowRequests += 1
        requestedItemID = itemId
        if paused {
            await withCheckedContinuation { continuation in
                pendingCompletion = continuation
            }
        }
        let startMs = max(0, anchorMediaTimeMs - windowBeforeMs)
        let endMs = min(durationMs ?? Int.max, anchorMediaTimeMs + windowAfterMs)
        let timeline = TranscriptTimeline(
            segments: [
                .init(
                    id: "recipient-prefix",
                    startMs: 4_000,
                    endMs: 5_000,
                    text: "the durable prefix has nearly enough unique words here"
                ),
                .init(
                    id: "recipient-suffix",
                    startMs: 6_000,
                    endMs: 7_000,
                    text: "the following suffix was also uniquely present right now"
                )
            ],
            chapters: [],
            durationMs: durationMs
        )
        return SourceAudioWindowTranscription(
            timeline: timeline, localAudioURL: nil,
            sourceStartMs: startMs, sourceEndMs: endMs,
            provenance: .downloadedSourceReference
        )
    }

    func fullRequestCount() -> Int {
        fullRequests
    }

    func windowRequestCount() -> Int {
        windowRequests
    }

    func lastRequestedItemID() -> String? {
        requestedItemID
    }

    func release() {
        paused = false
        pendingCompletion?.resume()
        pendingCompletion = nil
    }
}

private final class PackagePodcastLinkResolver: LinkResolutionClient {
    private let result: LinkResolutionResult

    init(result: LinkResolutionResult) {
        self.result = result
    }

    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: result.status,
            originalLink: SourceLink(
                url: request.inputURL,
                provider: result.originalLink.provider,
                title: result.originalLink.title,
                role: result.originalLink.role
            ),
            selectedCandidate: result.selectedCandidate,
            candidates: result.candidates,
            failureReason: result.failureReason
        )
    }
}

private final class FailingPackagePodcastLinkResolver: LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        throw URLError(.badServerResponse)
    }
}
