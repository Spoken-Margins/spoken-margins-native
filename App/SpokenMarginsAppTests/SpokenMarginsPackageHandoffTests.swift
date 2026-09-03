import XCTest
@testable import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
@testable import SpokenMarginsApp

final class SpokenMarginsPackageHandoffTests: XCTestCase {
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
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("recipient.sqlite")
        let packageURL = root.appendingPathComponent("different-episode.spokenmargins")
        let manifest = try writePodcastPackage(to: packageURL, packageID: "package-different-episode")
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
        let store = try SQLiteSessionStore(path: databaseURL.path)
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
    func testReopeningCorruptedWrongSourcePackageRepairsItsItemAssociation() async throws {
        let root = try temporaryDirectory(named: "spoken-margins-package-repair")
        defer { try? FileManager.default.removeItem(at: root) }
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
        defer { try? FileManager.default.removeItem(at: root) }
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
        let localURL = root.appendingPathComponent("recipient.mp3")
        try Data("recipient-edition".utf8).write(to: localURL)
        let store = try SQLiteSessionStore(path: databaseURL.path)
        let digest = try XCTUnwrap(manifest.contentDigest)
        let importedLayer = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: digest))
        let importedMargin = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: importedLayer.id).first)
        XCTAssertTrue(PodcastTranscriptAnchorResolver.hasUsableContext(importedMargin.anchorEvidence))
        model.podcastLocalAssetDidBecomeReady(itemId: item.id, url: localURL)
        for _ in 0..<250 {
            if await transcriber.fullRequestCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let fullRequestCount = await transcriber.fullRequestCount()
        XCTAssertEqual(fullRequestCount, 1)

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
        XCTAssertNil(try store.loadTranscriptTimeline(itemId: item.id))
        XCTAssertEqual(model.diagnostics["recipientAlignmentTranscript:\(item.id)"], "consumed_and_deleted")
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
    private var requestCount = 0

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        requestCount += 1
        return TranscriptTimeline(
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
    }

    func fullRequestCount() -> Int {
        requestCount
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
