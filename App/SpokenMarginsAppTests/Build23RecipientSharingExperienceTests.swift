import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Build23RecipientSharingExperienceTests: XCTestCase {
    func testMissingSourceReturnRestoresExplicitImportWithoutReopeningPackage() {
        let missingSource = recipientSnapshot(
            requiresRecipientSource: true,
            canImport: false
        )

        XCTAssertFalse(Build23RecipientPresentation.canConfirmImport(missingSource))
        XCTAssertEqual(
            Build23RecipientPresentation.primaryAction(for: missingSource),
            .addSource
        )

        let returnedWithResolvedSource = recipientSnapshot(
            requiresRecipientSource: false,
            canImport: true
        )

        XCTAssertTrue(Build23RecipientPresentation.canConfirmImport(returnedWithResolvedSource))
        XCTAssertEqual(
            Build23RecipientPresentation.primaryAction(for: returnedWithResolvedSource),
            .importPackage(enabled: true)
        )
        XCTAssertEqual(returnedWithResolvedSource.itemTitle, missingSource.itemTitle)
        XCTAssertEqual(returnedWithResolvedSource.senderLabel, missingSource.senderLabel)
        XCTAssertEqual(returnedWithResolvedSource.marginCount, missingSource.marginCount)
    }

    func testImportCannotBeConfirmedWhileSourceIsMissing() {
        let snapshot = recipientSnapshot(
            requiresRecipientSource: true,
            canImport: false
        )

        XCTAssertFalse(snapshot.canImport)
        XCTAssertFalse(Build23RecipientPresentation.canConfirmImport(snapshot))
        XCTAssertNotEqual(
            Build23RecipientPresentation.primaryAction(for: snapshot),
            .importPackage(enabled: true)
        )
    }

    func testCompanionIsTheDisplayedDefaultProjection() {
        let layer = importedLayer(revealMode: .companion)

        XCTAssertEqual(layer.revealMode, .companion)
        XCTAssertEqual(
            Build23ImportedLayerPresentation.revealModeLabel(layer.revealMode),
            "Companion"
        )
    }

    func testProvenanceUsesStableLabelAndSymbolRatherThanColorAlone() {
        let layer = importedLayer(revealMode: .companion)
        let label = Build23ImportedLayerPresentation.provenanceAccessibilityLabel(for: layer)

        XCTAssertFalse(Build23ImportedLayerPresentation.provenanceSymbolName.isEmpty)
        XCTAssertTrue(label.contains("separate shared layer"))
        XCTAssertTrue(label.contains("Sender label Cole"))
        XCTAssertTrue(label.contains("Integrity checked"))
        XCTAssertTrue(label.contains("not cryptographically verified"))
        XCTAssertTrue(label.contains("Source resolution Resolved"))
        XCTAssertTrue(label.contains("Layer enabled"))
        XCTAssertTrue(label.contains("Layer not muted"))
        XCTAssertTrue(label.contains("Reveal mode Companion"))
        XCTAssertTrue(label.contains("2 listening map proposals"))
    }

    func testImportDisclosureExplicitlyRulesOutAutoplay() {
        XCTAssertTrue(Build23RecipientPresentation.importNotice.contains("never starts playback"))
        XCTAssertTrue(Build23RecipientPresentation.importNotice.contains("separate layer"))
    }

    private func recipientSnapshot(
        requiresRecipientSource: Bool,
        canImport: Bool
    ) -> Build23RecipientImportSnapshot {
        Build23RecipientImportSnapshot(
            itemTitle: "Episode",
            senderLabel: "Cole",
            marginCount: 2,
            transport: .reference,
            includesEmbeddedItem: false,
            requiresRecipientSource: requiresRecipientSource,
            isImporting: false,
            errorMessage: nil,
            canImport: canImport
        )
    }

    private func importedLayer(
        revealMode: ImportedCommentaryRevealMode
    ) -> Build23ImportedLayerSnapshot {
        Build23ImportedLayerSnapshot(
            id: "layer-1",
            senderLabel: "Cole",
            itemTitle: "Episode",
            integrity: .integrityCheckedUnsigned,
            sourceResolution: .resolved,
            isEnabled: true,
            isMuted: false,
            revealMode: revealMode,
            listeningMapProposalCount: 2,
            margins: [
                Build23ImportedMarginSnapshot(
                    id: "margin-1",
                    reviewedText: "Notice the pause before the answer.",
                    resolution: .transcriptVerified,
                    positionDescription: "Chapter 2 · 08:14",
                    isPlayable: true,
                    hasVoice: true,
                    canReviewPosition: false,
                    canConfirmPosition: false,
                    listenAroundLabel: "Listen around current source position"
                )
            ]
        )
    }
}
