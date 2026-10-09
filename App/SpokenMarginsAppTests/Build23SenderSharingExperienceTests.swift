import Foundation
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23SenderSharingExperienceTests: XCTestCase {
    func testFirstShareChoiceIsRememberedAndControlsFutureDefault() {
        let defaults = UserDefaults.standard
        let priorDecision = defaults.object(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        let priorEnabled = defaults.object(forKey: ShareAutoCleanPreference.enabledKey)
        defer {
            restoreUserDefault(priorDecision, forKey: ShareAutoCleanPreference.decisionRecordedKey)
            restoreUserDefault(priorEnabled, forKey: ShareAutoCleanPreference.enabledKey)
        }
        defaults.removeObject(forKey: ShareAutoCleanPreference.decisionRecordedKey)
        defaults.removeObject(forKey: ShareAutoCleanPreference.enabledKey)

        let firstShare = makeCoordinator()
        firstShare.send(.begin)
        XCTAssertTrue(firstShare.snapshot.needsAutoCleanDecision)
        XCTAssertFalse(firstShare.snapshot.autoCleanSelectedEnabled)

        firstShare.send(.setAutoCleanSelectedEnabled(true))
        XCTAssertFalse(firstShare.snapshot.needsAutoCleanDecision)
        XCTAssertTrue(firstShare.snapshot.autoCleanSelectedEnabled)

        let laterShare = makeCoordinator()
        laterShare.send(.begin)
        XCTAssertFalse(laterShare.snapshot.needsAutoCleanDecision)
        XCTAssertTrue(laterShare.snapshot.autoCleanSelectedEnabled)

        laterShare.send(.setAutoCleanSelectedEnabled(false))
        XCTAssertFalse(laterShare.snapshot.autoCleanSelectedEnabled)
        XCTAssertFalse(defaults.bool(forKey: ShareAutoCleanPreference.enabledKey))
    }

    func testBulkSelectionCanIncludeOrExcludeEveryVisibleMarginInOneAction() {
        let coordinator = makeCoordinator(marginCount: 3)
        coordinator.send(.begin)
        let visibleIDs = coordinator.snapshot.margins.map(\.id)

        coordinator.send(.setVisibleIncluded(ids: visibleIDs, included: false))
        XCTAssertTrue(coordinator.snapshot.margins.allSatisfy { !$0.isIncluded })

        coordinator.send(.setVisibleIncluded(ids: visibleIDs, included: true))
        XCTAssertTrue(coordinator.snapshot.margins.allSatisfy(\.isIncluded))
    }

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

    /// #536: a failed share offers "Share without episode matching" while matching data is included.
    func testAFailedShareOffersSharingWithoutEpisodeMatching() {
        let failed = Build23SharingPreviewState.failed("episode fingerprint spine is out of bounds: canonical_url")
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(previewState: failed, includesAcousticEvidence: true))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: failed, includesAcousticEvidence: false))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .ready, includesAcousticEvidence: true))
        XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .notBuilt, includesAcousticEvidence: true))
        // Failures that turning matching off can't fix offer nothing.
        for unrelated in ["Select at least one Margin with reviewed text.", "Finish or cancel bulk preparation before sharing.", "The package could not be built."] {
            XCTAssertFalse(Build23SenderPresentation.offersShareWithoutMatching(previewState: .failed(unrelated), includesAcousticEvidence: true), unrelated)
        }
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(
            previewState: .failed("The package manifest is invalid: episode fingerprint landmark is invalid: signature_asset."), includesAcousticEvidence: true
        ))
        XCTAssertTrue(Build23SenderPresentation.offersShareWithoutMatching(
            previewState: .failed("A package asset is unreadable: assets/evidence/episode-signature-item-grid-3.shazamsignature."), includesAcousticEvidence: true
        ))
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
        XCTAssertTrue(Build23SenderPresentation.stageOwnsBatchPreparation(.select))
        XCTAssertTrue(Build23SenderPresentation.stageOwnsDetailedEditor(.review))
        XCTAssertFalse(Build23SenderPresentation.stageOwnsBatchPreparation(.review))

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

    /// #1185: a voice Margin with no transcript is "included" in the list but can't go in the
    /// packet, so the Review and Share buttons must not count it.
    func testTheShareButtonsCountOnlyMarginsThePacketCanCarry() {
        let coordinator = makeCoordinator(marginCount: 2, marginsWithoutTranscript: [0])
        coordinator.send(.begin)
        let snapshot = coordinator.snapshot

        XCTAssertEqual(snapshot.margins.filter(\.isIncluded).count, 2)
        XCTAssertEqual(snapshot.selectionSummary.packetCount, 1)
        XCTAssertEqual(snapshot.selectionSummary.notice, "1 Margin has no transcript and wasn't included.")
        let leftOut = snapshot.margins.filter(\.isLeftOutForMissingText)
        XCTAssertEqual(leftOut.count, 1)
        XCTAssertEqual(leftOut.first?.reviewedText, "")
    }

    private func makeCoordinator(marginCount: Int = 1, marginsWithoutTranscript: Set<Int> = []) -> Build23SharingCoordinator {
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
            let transcript: String = marginsWithoutTranscript.contains(index) ? "" : "Reviewed Margin \(index)."
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

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
