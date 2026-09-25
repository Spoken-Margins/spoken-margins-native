import XCTest
import Combine
import SessionKitSharing
import SessionKitPersistence
import SessionKitAudio
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SharingSeamsTests: XCTestCase {
    func testRecipientPositionReviewDoesNotArmAfterRejectedSeek() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let localURL = root.appending(path: "episode.caf")
        try Data("episode bytes".utf8).write(to: localURL)
        let model = Gate1AppModel(audioPlaybackClient: RejectingRecipientSeekAudioClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        let item = Item(id: "reject-seek-podcast", title: "Episode", mediaType: "podcast", text: nil,
            externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 60_000))
        try store.saveItem(item)
        let layer = ImportedCommentaryLayer(id: "reject-seek-layer", itemId: item.id,
            packageDigest: "reject-seek-packet", packageId: "packet",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: item.title),
            importedAt: Date(), sourceResolutionStatus: .ambiguous)
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "reject-seek-margin", layerId: layer.id, packageScopedId: "margin", createdAt: Date(),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 20_000),
            approvedTranscript: "Shared words", resolution: ImportedAnchorResolution(evidenceClass: .ambiguous)
        ))
        model.openItem(id: item.id)
        model.startItem(id: item.id)
        model.useRecipientPodcastFileForTests(itemID: item.id, url: localURL)
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.listenAroundPosition(layerID: layer.id, marginID: "reject-seek-margin"))
        XCTAssertFalse(coordinator.importedLayers.first?.margins.first?.canConfirmPosition ?? true)
        coordinator.send(.confirmPosition(layerID: layer.id, marginID: "reject-seek-margin"))
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: layer.id).first?.resolution.evidenceClass,
                       .ambiguous)
        XCTAssertNil(try store.loadImportedCommentaryLayer(id: layer.id)?.resolvedRecipientEditionSHA256)
    }

    func testRecipientPositionConfirmationPersistsAndChangedEditionInvalidatesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let localURL = root.appending(path: "recipient-episode.caf")
        try Data("recipient edition A".utf8).write(to: localURL)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        let item = Item(id: "recipient-confirmation-podcast", title: "Recipient episode", mediaType: "podcast",
            text: nil, externalReference: "https://example.com/episode", status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/episode.mp3", durationMs: 60_000))
        try store.saveItem(item)
        let layer = ImportedCommentaryLayer(
            id: "recipient-layer", itemId: item.id, packageDigest: "recipient-packet", packageId: "packet",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: item.title), displayLabel: "Friend",
            importedAt: Date(), sourceResolutionStatus: .ambiguous, isEnabled: true
        )
        try store.saveImportedCommentaryLayer(layer)
        for id in ["first", "second"] {
            try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
                id: id, layerId: layer.id, packageScopedId: id, createdAt: Date(),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 20_000),
                approvedTranscript: "Shared voice \(id)", audioPath: "SpokenMargins/shared-voice.m4a",
                resolution: ImportedAnchorResolution(evidenceClass: .ambiguous)
            ))
        }
        model.openItem(id: item.id)
        model.startItem(id: item.id)
        model.useRecipientPodcastFileForTests(itemID: item.id, url: localURL)
        let coordinator = Build23SharingCoordinator(model: model)
        let first = try XCTUnwrap(coordinator.importedLayers.first?.margins.first { $0.id == "first" })
        XCTAssertTrue(first.hasVoice, "Unresolved shared voice must retain its direct Listen action")
        XCTAssertTrue(first.canReviewPosition)
        XCTAssertFalse(first.canConfirmPosition)
        XCTAssertEqual(first.listenAroundLabel, "Listen around suggested position")

        model.pause()
        XCTAssertEqual(model.snapshot.status, .paused)
        coordinator.send(.listenAroundPosition(layerID: layer.id, marginID: "first"))
        XCTAssertEqual(model.snapshot.status, .playing, "Review must resume a paused source before enabling confirmation")
        XCTAssertFalse(coordinator.importedLayers.first?.margins.first { $0.id == "first" }?.canConfirmPosition ?? true,
                       "A missing local-transport probe cannot prove recipient playback")
        model.useRecipientPlaybackURLProbeForTests { _, _ in false }
        coordinator.send(.listenAroundPosition(layerID: layer.id, marginID: "first"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(coordinator.importedLayers.first?.margins.first { $0.id == "first" }?.canConfirmPosition ?? true,
                       "A probe observing only the remote transport cannot arm confirmation")
        model.useRecipientPlaybackURLProbeForTests { url, itemID in
            url.standardizedFileURL == localURL.standardizedFileURL && itemID == item.id
        }
        coordinator.send(.listenAroundPosition(layerID: layer.id, marginID: "first"))
        for _ in 0..<150 where coordinator.importedLayers.first?.margins.first(where: { $0.id == "first" })?.canConfirmPosition != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(coordinator.importedLayers.first?.margins.first { $0.id == "first" }?.canConfirmPosition == true)
        model.seekMedia(toMediaTimeMs: 23_000)
        coordinator.send(.confirmPosition(layerID: layer.id, marginID: "first"))
        let confirmed = try XCTUnwrap(store.loadImportedCommentaryInterjections(layerId: layer.id).first { $0.id == "first" })
        XCTAssertEqual(confirmed.resolution.evidenceClass, .recipientConfirmed)
        XCTAssertEqual(confirmed.resolution.localMediaTimeMs, 23_000)
        XCTAssertEqual(confirmed.resolution.algorithmVersion, "recipient-confirmation.v1")
        let digestA = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
        XCTAssertEqual(try store.loadImportedCommentaryLayer(id: layer.id)?.resolvedRecipientEditionSHA256, digestA)
        XCTAssertFalse(coordinator.importedLayers.first?.margins.first { $0.id == "first" }?.canReviewPosition ?? true)

        let reopened = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        reopened.bootstrapLibraryIfNeeded()
        reopened.openItem(id: item.id)
        XCTAssertEqual(reopened.selectedItem.importedCommentaryInterjections[layer.id]?
            .first(where: { $0.id == "first" })?.resolution.evidenceClass, .recipientConfirmed)

        coordinator.send(.listenAroundPosition(layerID: layer.id, marginID: "second"))
        XCTAssertTrue(coordinator.importedLayers.first?.margins.first { $0.id == "second" }?.canConfirmPosition == true)
        try Data("recipient edition B".utf8).write(to: localURL, options: .atomic)
        coordinator.send(.confirmPosition(layerID: layer.id, marginID: "second"))
        let afterChange = try store.loadImportedCommentaryInterjections(layerId: layer.id)
        XCTAssertTrue(afterChange.allSatisfy { $0.resolution.evidenceClass == .unresolved })
        XCTAssertNil(try store.loadImportedCommentaryLayer(id: layer.id)?.resolvedRecipientEditionSHA256)
        XCTAssertFalse(coordinator.importedLayers.first?.margins.first { $0.id == "second" }?.canConfirmPosition ?? true)
    }

    func testSharingCoordinatorIgnoresPlaybackAndDiagnosticTicks() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let coordinator = Build23SharingCoordinator(model: model)
        // Drain initialization notifications before observing unrelated changes.
        for _ in 0..<8 { await Task.yield() }
        var notifications = 0
        let subscription = coordinator.objectWillChange.sink { notifications += 1 }
        for index in 0..<100 {
            model.snapshot.currentMediaTimeMs = index * 500
            model.diagnostics["test-tick"] = String(index)
        }
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(notifications, 0, "Audio progress must not rebuild shared-Margin presentation")
        coordinator.send(.setSenderDisplayLabel("A changed sharing input"))
        XCTAssertGreaterThan(notifications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testTwoMarginsWithLocalSkimReferencesProduceVerifiedShareFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let store = try SQLiteSessionStore(path: db.path)
        let itemID = model.selectedItem.id
        let proposal = PortableListeningMapProposalArtifact(
            id: "local-map", createdAt: Date(timeIntervalSince1970: 1), generator: "test",
            scenes: [PortableListeningMapScene(id: "scene", order: 0, title: "Opening",
                summaryText: "A summary to retain", summaryAssetId: "unselected-local-summary",
                summaryProvenance: .modelGenerated, eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .text, roughPercent: 0),
                endAnchor: PortableAnchorEvidence(anchorType: .text, roughPercent: 100))]
        )
        try store.savePortableListeningMapProposal(proposal, itemId: itemID)
        model.selectedItem.interjections = (1...2).map { index in
            Interjection(id: "margin-\(index)", itemId: itemID, sessionId: "session-test",
                targetType: .item, targetId: itemID, createdAt: Date(), roughPercent: index * 20,
                anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                transcript: "Reviewed Margin \(index)", cleanedTranscript: nil, displayText: nil, status: "active")
        }
        try model.persistSelectedInterjectionsForSharingTests()
        let coordinator = Build23SharingCoordinator(model: model)
        coordinator.send(.begin)
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)
        for _ in 0..<100 where coordinator.previewState == .building { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(coordinator.previewState, .ready)
        let url = try XCTUnwrap(coordinator.verifiedShareFileURL)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(coordinator.verifiedPreview?.margins.count, 2)
        let exported = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appending(path: "verified-assets"))
        XCTAssertNil(exported.listeningMapProposals.first?.scenes.first?.summaryAssetId)
        XCTAssertEqual(exported.listeningMapProposals.first?.scenes.first?.summaryText, "A summary to retain")
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: itemID).first, proposal, "Sharing must not mutate the local map or its usable Skim audio")
        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.stage, .share)
    }

    func testSenderStageVocabularyIsFrozenInReleaseOrder() {
        XCTAssertEqual(
            Build23SharingStage.allCases.map(\.rawValue),
            ["select", "review", "recipient_preview", "share"]
        )
    }

    func testRecipientPreviewComesFromVerifiedFileAndMutationInvalidatesIt() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        model.selectedItem.interjections = [Interjection(
            id: "margin-build-23-seam",
            itemId: itemID,
            sessionId: "session-build-23-seam",
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
            transcript: "A reviewed Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        try model.persistSelectedInterjectionsForSharingTests()
        let coordinator = Build23SharingCoordinator(model: model)

        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .select)
        XCTAssertEqual(coordinator.snapshot.margins.map(\.id), ["margin-build-23-seam"])
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        coordinator.send(.buildRecipientPreview)

        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let preview = try XCTUnwrap(coordinator.snapshot.verifiedPreview)
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        XCTAssertEqual(preview.margins.map(\.reviewedText), ["A reviewed Margin."])
        XCTAssertFalse(preview.contentDigest.isEmpty)
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertFalse(model.isSharedSpokenMarginsPackagePresented)

        coordinator.send(.setSenderDisplayLabel("Changed after preview"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
        try? FileManager.default.removeItem(at: preview.fileURL)
    }
    func testAcousticOptOutOmitsStoredEditionSpineAndRetainsReviewedDisclosures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "evidence-opt-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: db)
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        let store = try SQLiteSessionStore(path: db.path)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: "stored-spine", itemId: itemID, landmarks: [
                EpisodeFingerprintLandmark(id: "landmark", order: 0, sourceMediaStartMs: 0,
                    sourceMediaEndMs: 12_000, anchorMediaTimeMs: 6_000, continuityEpoch: 0,
                    trigger: .initialPlayback, provenance: .observedDecodedPlayback,
                    signatureAssetId: "signature-the-user-excluded")
            ]
        ))
        model.selectedItem.interjections = [Interjection(
            id: "margin-build-23-seam",
            itemId: itemID,
            sessionId: "session-build-23-seam",
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
            transcript: "A reviewed Margin.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )]
        try model.persistSelectedInterjectionsForSharingTests()
        let coordinator = Build23SharingCoordinator(model: model)

        coordinator.send(.begin)
        XCTAssertEqual(coordinator.snapshot.stage, .select)
        XCTAssertEqual(coordinator.snapshot.margins.map(\.id), ["margin-build-23-seam"])
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        coordinator.send(.setIncludesAcousticEvidence(false))
        coordinator.send(.buildRecipientPreview)

        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        let preview = try XCTUnwrap(coordinator.snapshot.verifiedPreview)
        XCTAssertEqual(coordinator.snapshot.stage, .recipientPreview)
        XCTAssertEqual(preview.margins.map(\.reviewedText), ["A reviewed Margin."])
        XCTAssertFalse(preview.contentDigest.isEmpty)
        let verified = try SpokenMarginsPackageArchive.read(from: preview.fileURL, extractingAssetsTo: root.appending(path: "assets"))
        XCTAssertTrue(verified.editionFingerprintSpines.isEmpty)
        XCTAssertFalse(verified.manifest.assets.contains { $0.role == SpokenMarginsAssetRole.acousticSignature })
        XCTAssertTrue(verified.commentaryLayers.flatMap(\.interjections).allSatisfy { $0.anchor.machineEvidenceAssetIds.isEmpty })
        XCTAssertTrue(preview.disclosures.contains(SharingRightsPresentation.rightsNotice))
        XCTAssertTrue(preview.disclosures.contains(SharingRightsPresentation.recipientCopiesNotice))
        XCTAssertTrue(preview.disclosures.contains { $0.contains("Context before: Before") })
        XCTAssertTrue(preview.disclosures.contains { $0.contains("Context after: After") })
        XCTAssertTrue(preview.disclosures.contains { $0.contains("text only; no recording") })
        XCTAssertNotNil(try store.loadEditionFingerprintSpine(itemId: itemID), "Opt-out must not delete locally useful evidence")
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.fileURL.path))
        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertFalse(model.isSharedSpokenMarginsPackagePresented)

        coordinator.send(.setSenderDisplayLabel("Changed after preview"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
        try? FileManager.default.removeItem(at: preview.fileURL)
    }
}

private struct RejectingRecipientSeekAudioClient: AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func pause() throws {}
    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        throw SessionKitError.persistenceFailed("injected_recipient_seek_failure")
    }
}
