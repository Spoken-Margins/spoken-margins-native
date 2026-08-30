import Foundation
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SenderSharingExperienceTests: XCTestCase {
    func testStageGatingKeepsSenderInSelectWithoutAnIncludedMargin() {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)
        coordinator.send(.setPrivateSharingRightsConfirmed(true))

        let marginID = coordinator.snapshot.margins[0].id
        coordinator.send(.setIncluded(id: marginID, included: false))

        XCTAssertFalse(coordinator.snapshot.canAdvance)
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .select)

        coordinator.send(.setIncluded(id: marginID, included: true))
        XCTAssertTrue(coordinator.snapshot.canAdvance)
        coordinator.send(.advanceToReview)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
    }

    func testPresentationReturnsExactlyOneExpandedEditorForTheSelectedMargin() {
        let coordinator = makeCoordinator(marginCount: 2)
        coordinator.send(.begin)

        XCTAssertEqual(Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).count, 1)

        let secondMarginID = coordinator.snapshot.margins[1].id
        coordinator.send(.selectMargin(secondMarginID))
        XCTAssertEqual(
            Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).map(\.id),
            [secondMarginID]
        )

        coordinator.send(.selectMargin(nil))
        XCTAssertTrue(Build23SenderPresentation.expandedMargins(in: coordinator.snapshot).isEmpty)
    }

    func testPackageMutationInvalidatesVerifiedRecipientPreviewAsStale() async throws {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)
        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        coordinator.send(.advanceToReview)
        coordinator.send(.buildRecipientPreview)

        let preview = try await waitForVerifiedPreview(from: coordinator)
        defer { try? FileManager.default.removeItem(at: preview.fileURL) }

        XCTAssertEqual(coordinator.snapshot.previewState, .ready)
        XCTAssertEqual(coordinator.verifiedShareFileURL, preview.fileURL)

        coordinator.send(.setAnchorBefore(id: coordinator.snapshot.margins[0].id, text: "Changed context"))

        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNotEqual(coordinator.snapshot.previewState, .ready)
        XCTAssertNil(coordinator.snapshot.verifiedPreview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
    }

    func testShareURLIsAbsentAndShareStageIsGatedBeforeVerification() {
        let coordinator = makeCoordinator()
        coordinator.send(.begin)

        XCTAssertNil(coordinator.verifiedShareFileURL)
        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.snapshot.stage, .select)

        coordinator.send(.setPrivateSharingRightsConfirmed(true))
        coordinator.send(.advanceToReview)
        XCTAssertNil(coordinator.verifiedShareFileURL)
        XCTAssertFalse(coordinator.snapshot.canShareVerifiedFile)

        coordinator.send(.presentSystemShare)
        XCTAssertEqual(coordinator.snapshot.stage, .review)
        XCTAssertNil(coordinator.verifiedShareFileURL)
    }

    func testSelectAndReviewOwnDistinctPresentationSurfaces() {
        XCTAssertFalse(Build23SenderPresentation.stageOwnsDetailedEditor(.select))
        XCTAssertFalse(Build23SenderPresentation.stageOwnsBatchPreparation(.select))
        XCTAssertTrue(Build23SenderPresentation.stageOwnsDetailedEditor(.review))
        XCTAssertTrue(Build23SenderPresentation.stageOwnsBatchPreparation(.review))

        let coordinator = makeCoordinator(marginCount: 2)
        coordinator.send(.begin)
        let selectedMarginID = coordinator.snapshot.margins[0].id
        coordinator.send(.setIncluded(id: selectedMarginID, included: false))

        let reviewEditors = Build23SenderPresentation.reviewExpandedMargins(in: coordinator.snapshot)
        XCTAssertEqual(reviewEditors.count, 1)
        XCTAssertTrue(reviewEditors[0].isIncluded)
        XCTAssertNotEqual(reviewEditors[0].id, selectedMarginID)
    }

    func testReferenceTransportNeverRequiresPayloadRightsAssertion() {
        XCTAssertFalse(Build23SenderPresentation.showsLinklessRightsControl(for: .reference))
        XCTAssertFalse(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .reference))
        XCTAssertFalse(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .recipientSupplied))
        XCTAssertTrue(Build23SenderPresentation.requiresPayloadRightsAssertion(for: .embeddedText))
    }

    private func makeCoordinator(marginCount: Int = 1) -> Build23SharingCoordinator {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        let itemID = model.selectedItem.id
        var interjections: [Interjection] = []
        interjections.reserveCapacity(marginCount)

        for index in 0..<marginCount {
            let marginID: String = "margin-build-23-sender-\(index)"
            let sessionID: String = "session-build-23-sender"
            let createdAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
            let roughPercent: Int = (index + 1) * 20
            let startCharacter = index * 5
            let endCharacter = startCharacter + 5
            let anchor = Anchor(
                anchorType: .text,
                startChar: startCharacter,
                endChar: endCharacter,
                anchorBefore: "Before \(index)",
                anchorAfter: "After \(index)"
            )
            let transcript: String = "Reviewed Margin \(index)."
            let interjection = Interjection(
                id: marginID,
                itemId: itemID,
                sessionId: sessionID,
                targetType: .item,
                targetId: itemID,
                createdAt: createdAt,
                roughPercent: roughPercent,
                anchor: anchor,
                audioPath: nil,
                audioStatus: "none",
                transcriptionStatus: "transcribed",
                transcript: transcript,
                cleanedTranscript: nil,
                displayText: nil,
                status: "active"
            )
            interjections.append(interjection)
        }
        model.selectedItem.interjections = interjections
        return Build23SharingCoordinator(model: model)
    }

    private func waitForVerifiedPreview(
        from coordinator: Build23SharingCoordinator
    ) async throws -> Build23VerifiedRecipientPreview {
        for _ in 0..<100 where coordinator.snapshot.previewState != .ready {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(coordinator.snapshot.verifiedPreview)
    }
}
