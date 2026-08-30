import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SharingSeamsTests: XCTestCase {
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
}
