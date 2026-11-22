import XCTest
@testable import SessionKit
import SessionKitAudio
@testable import SpokenMarginsApp

/// The playback screen's Margins tab, Play on a friend's Margin on an article or PDF (#4447). The row lists such a
/// Margin at its passage; its Play button used to ask for a time in the item, which text has none of, so it was
/// disabled and a tap could only fail.
@MainActor
final class MarginsListPlayAppTests: XCTestCase {
    /// A written Margin starts a reading on the shared reader when it plays; a render left running would make a later
    /// test's reading wait behind it (#3423), so a leak fails the test that made it (audit on 1e7362f).
    override func tearDown() async throws {
        await ReturnFixture.expectSharedReaderIdle()
        try await super.tearDown()
    }

    private func articleModelWithFriendMargin() -> (model: Gate1AppModel, row: SharedMarginRow) {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let layer = ImportedCommentaryLayer(
            id: "layer-received", itemId: "item-pill", packageDigest: "digest-received", packageId: "package-received",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "You Can't Inspect the Pill"), displayLabel: "Cole",
            importedAt: Date(timeIntervalSince1970: 42), sourceResolutionStatus: .resolved, isEnabled: true, isMuted: true,
            revealMode: .companion
        )
        let record = ImportedCommentaryInterjection(
            id: "received-margin-7", layerId: layer.id, packageScopedId: "margin-7", createdAt: Date(timeIntervalSince1970: 43),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: 120, endChar: 140),
            approvedTranscript: "Remember this part.",
            resolution: ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 120, localEndChar: 140, confidence: 1)
        )
        model.selectedItem.importedCommentaryLayers = [layer]
        model.selectedItem.importedCommentaryInterjections = [layer.id: [record]]
        return (model, SharedMarginRow(interjection: record, layer: layer, itemTitle: "You Can't Inspect the Pill"))
    }

    func testAFriendsMarginMatchedInAnArticleHasAnEnabledPlayAndATapGoesToItsPassage() {
        let (model, row) = articleModelWithFriendMargin()
        XCTAssertNil(SharedMarginPlaybackPosition(row.interjection), "an article Margin has no time in the item")
        XCTAssertTrue(row.canPlayFromMarginsList, "the Margins tab's Play is enabled at a matched passage")

        model.playSharedMarginFromMarginsList(row)

        XCTAssertNil(model.lastError, "the tap says nothing is wrong")
        XCTAssertEqual(model.pendingImportedCommentary?.id, row.interjection.id, "it went to the passage and offered the Margin")
        XCTAssertEqual(model.diagnostics["lastSharedMarginNavigation"], "opened:received-margin-7")
    }

    // A friend's article Margin that is never read aloud (#4934): its row goes to the passage and plays on, with no Margin offered.
    func testAFriendsSilentMarginMatchedInAnArticleGoesToItsPassageWithNothingOffered() {
        let (model, row) = articleModelWithFriendMargin()
        var record = row.interjection
        record.senderReadAloud = false
        let silent = SharedMarginRow(interjection: record, layer: row.layer, itemTitle: row.itemTitle)
        XCTAssertFalse(silent.canPlayFromMarginsList, "nothing to play")
        XCTAssertTrue(silent.goesToFromList, "the row's button goes to the passage")

        model.goToSharedMargin(silent)

        XCTAssertNil(model.lastError)
        XCTAssertNil(model.pendingImportedCommentary, "nothing is offered or spoken")
        XCTAssertNil(model.marginMoment)
        XCTAssertEqual(model.silentMarginLanding?.position, 120, "the card is for the passage's own character offset")
        XCTAssertEqual(model.silentMarginLanding?.words, "Remember this part.")
        XCTAssertEqual(model.screen, .playback)
    }

    func testATapOnAMarginOfAnotherItemSaysSoAndMovesNothing() {
        let (model, row) = articleModelWithFriendMargin()
        var elsewhere = row.layer
        elsewhere.itemId = "some-other-item"
        model.playSharedMarginFromMarginsList(SharedMarginRow(interjection: row.interjection, layer: elsewhere, itemTitle: "Elsewhere"))

        XCTAssertNotNil(model.lastError)
        XCTAssertNil(model.pendingImportedCommentary)
    }

    func testAFriendsMarginOnALayerTurnedOffHasNoPlayAndATapSaysWhy() {
        let (model, row) = articleModelWithFriendMargin()
        var off = row.layer
        off.isEnabled = false
        let offRow = SharedMarginRow(interjection: row.interjection, layer: off, itemTitle: row.itemTitle)
        XCTAssertFalse(offRow.canPlayFromMarginsList, "the layer is off: nothing for the button to start")

        model.playSharedMarginFromMarginsList(offRow)

        XCTAssertEqual(model.lastError, "This friend's Margins are turned off. Turn them on to hear this one.",
                       "the real reason, not 'isn't ready'")
        XCTAssertNil(model.pendingImportedCommentary)
    }
}
