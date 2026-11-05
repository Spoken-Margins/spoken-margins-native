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

    func testAMapPacketSaysMapNotMarginsAndAsksBeforeReplacing() throws {
        var snapshot = recipientSnapshot(requiresRecipientSource: false, canImport: true)
        XCTAssertEqual(Build23RecipientPresentation.heading(for: snapshot), "From Cole")
        XCTAssertEqual(Build23RecipientPresentation.confirmTitle(for: snapshot), "Import")
        XCTAssertNil(Build23RecipientPresentation.notice(for: snapshot), "A friend's Margins carry no engineering notice (#3247)")

        snapshot.mapChapterCount = 7
        XCTAssertEqual(Build23RecipientPresentation.heading(for: snapshot), "Shared Listening Map")
        XCTAssertEqual(Build23RecipientPresentation.confirmTitle(for: snapshot), "Add Map")
        XCTAssertEqual(Build23RecipientPresentation.progressTitle(for: snapshot), "Adding…")
        XCTAssertFalse(try XCTUnwrap(Build23RecipientPresentation.notice(for: snapshot)).contains("replaces"))

        snapshot.replacesExistingMap = true
        XCTAssertEqual(Build23RecipientPresentation.confirmTitle(for: snapshot), "Replace Map")
        XCTAssertTrue(try XCTUnwrap(Build23RecipientPresentation.notice(for: snapshot)).contains("replaces it"))
        XCTAssertTrue(try XCTUnwrap(Build23RecipientPresentation.notice(for: snapshot)).contains("never starts playback"))
        XCTAssertTrue(Build23RecipientPresentation.canConfirmImport(snapshot))
    }

    func testCompanionIsTheDisplayedDefaultProjection() {
        let layer = importedLayer(revealMode: .companion)

        XCTAssertEqual(layer.revealMode, .companion)
        XCTAssertEqual(
            Build23ImportedLayerPresentation.playModeLabel(layer.revealMode),
            "A tone marks each one"
        )
    }

    func testProvenanceUsesStableLabelAndSymbolRatherThanColorAlone() {
        let layer = importedLayer(revealMode: .companion)
        let label = Build23ImportedLayerPresentation.provenanceAccessibilityLabel(for: layer)

        XCTAssertFalse(Build23ImportedLayerPresentation.provenanceSymbolName.isEmpty)
        XCTAssertTrue(label.hasPrefix("From Cole"))
        XCTAssertTrue(label.contains("Cole's Margins are on"))
        XCTAssertTrue(label.contains("Not muted"))
        XCTAssertTrue(label.contains("When Margins play: A tone marks each one"))
        for term in ["layer", "Integrity", "cryptographically", "Reveal mode", "Source resolution"] {
            XCTAssertFalse(label.localizedCaseInsensitiveContains(term), term)
        }
    }

    func testImportDisclosureExplicitlyRulesOutAutoplay() {
        XCTAssertEqual(Build23RecipientPresentation.aboutNote, "Unchanged since it was sent. The name on it comes from the sender's app and isn't proven.")
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
                    hasVoice: true
                )
            ]
        )
    }
}
