import XCTest
import Combine
import SessionKitSharing
import SessionKitPersistence
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SharingSeamsTests: XCTestCase {
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
