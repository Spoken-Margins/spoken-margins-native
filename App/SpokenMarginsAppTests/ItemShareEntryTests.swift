import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4229: the item screen's Share is the player's friend sheet started on the open item, or an explanation of why there is
/// nothing to send. These drive the model calls the header button and the options-menu row both make, from the item screen.
@MainActor
final class ItemShareEntryTests: XCTestCase {
    private var restoreTerms: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreTerms = acceptTerms()
    }

    override func tearDown() {
        restoreTerms?()
        super.tearDown()
    }

    /// The Terms gate holds text playback on a fresh simulator, so accept them for the test and put them back.
    private func acceptTerms() -> () -> Void {
        let keys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
        return {
            for (key, value) in zip(keys, prior) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    /// A seeded model with `count` written Margins on "item-pill", left on that item's screen.
    private func modelWithMargins(_ count: Int) -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        for index in 0..<count {
            model.beginWrittenMargin()
            model.saveWrittenMargin(text: "Thought \(index)")
        }
        model.refreshMarginRows()
        model.openItem(id: "item-pill")
        return model
    }

    func testOneMarginSharesAndOpensTheSheetOnItsReview() async {
        let model = modelWithMargins(1)

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share)
        model.openItemShareSheet()

        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.entry, .reviewDefaults, "the item screen opens the review, as the player does")
        XCTAssertEqual(model.sharingState.drafts.count, 1)
        XCTAssertEqual(model.selectedItem.id, "item-pill")
    }

    func testAnItemMarkedCompleteStillShares() async {
        let model = modelWithMargins(1)
        model.markItemCompleted(id: "item-pill")

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share, "finishing an item never hides or changes Share")
        model.openItemShareSheet()
        XCTAssertTrue(model.isSharingInterjectionsPresented)
    }

    func testAnItemWithNoMarginsSaysWhyAndOpensNothing() async {
        let model = modelWithMargins(0)

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .nothingYet(.init(title: "Nothing to share yet", message: ItemShareStart.noMarginsMessage)))
        XCTAssertFalse(model.isSharingInterjectionsPresented)
        XCTAssertTrue(model.sharingState.drafts.isEmpty)
        XCTAssertNil(model.feedbackEvent, "an expected state is explained by the alert, not reported as an error banner")
    }

    /// The rows lag a Margin saved a moment ago, so a first "nothing" is re-read from the store before it is believed.
    func testStaleRowsAreReReadBeforeSayingThereIsNothing() async {
        let model = modelWithMargins(1)
        model.marginRows = []

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share, "the Margin is in the store, so the re-read finds it and no alert is shown")
    }

    /// A second tap while the sheet is up must not rebuild its drafts and throw away what the listener chose.
    func testASecondTapKeepsTheListenersChoices() async throws {
        let model = modelWithMargins(1)
        _ = await model.itemShareStart()
        model.openItemShareSheet()
        let draft = try XCTUnwrap(model.sharingState.drafts.first)
        model.setShareDraftIncluded(draft.id, included: false)

        model.openItemShareSheet()

        XCTAssertFalse(try XCTUnwrap(model.sharingState.drafts.first { $0.id == draft.id }).isIncluded,
                       "the draft the listener excluded stays excluded")
    }

    /// Item B's screen opens B's Margins while item A is the one playing; A keeps playing.
    func testShareOnAnotherItemsScreenSharesThatItemAndLeavesPlaybackAlone() async throws {
        let model = modelWithMargins(0)
        model.importTitle = "Second Item"
        model.importText = "A second item with a thought of its own."
        model.importTextItem()
        let secondID = model.selectedItem.id
        model.startItem(id: secondID)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Second item thought")
        model.startItem(id: "item-pill")
        model.refreshMarginRows()
        model.openItem(id: secondID)

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share)
        model.openItemShareSheet()

        XCTAssertEqual(model.snapshot.itemId, "item-pill", "the first item is still the one playing")
        XCTAssertEqual(model.selectedItem.id, secondID)
        XCTAssertEqual(model.sharingState.drafts.map(\.interjection.itemId), [secondID], "the sheet holds the open item's Margin")
    }

    // MARK: A friend's item

    /// A friend's packet imported onto `itemId` with one Margin of theirs, stored for real, then the rows re-read.
    private func giveFriendMargin(_ model: Gate1AppModel, itemId: String, importedAt: Date, from name: String = "Ana") throws {
        let store = try model.requireStore()
        var layer = ImportedCommentaryLayer(
            id: "friend-layer-\(itemId)", itemId: itemId, packageDigest: String(repeating: "c", count: 64), packageId: "package-\(itemId)",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "Seeded"), displayLabel: name, importedAt: importedAt)
        layer.isEnabled = true
        try store.saveImportedCommentaryLayer(layer)
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "friend-margin-\(itemId)", layerId: layer.id, packageScopedId: "friend-margin-001", createdAt: importedAt,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "\(name)'s note",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition)))
        model.refreshMarginRows()
    }

    /// Share sends the listener's own Margins, so a friend's alone give the alert that says so (Design message 2).
    func testAFriendsMarginsAloneSayShareSendsYourOwn() async throws {
        let model = modelWithMargins(0)
        try giveFriendMargin(model, itemId: "item-pill", importedAt: Date().addingTimeInterval(-3600))

        let start = await model.itemShareStart()

        XCTAssertEqual(start, .nothingYet(.init(title: ItemShareStart.nothingYetTitle, message: ItemShareStart.onlyFriendMarginsMessage)))
        XCTAssertFalse(model.isSharingInterjectionsPresented)
        XCTAssertNil(model.feedbackEvent)
    }

    /// The listener has answered since the packet came: the sheet opens as the reply sheet, with the answer picked.
    func testAnAnsweredFriendsItemOpensTheReplySheet() async throws {
        let model = modelWithMargins(0)
        try giveFriendMargin(model, itemId: "item-pill", importedAt: Date().addingTimeInterval(-3600))
        model.startItem(id: "item-pill")
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "My answer")
        model.refreshMarginRows()
        model.openItem(id: "item-pill")

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share)
        model.openItemShareSheet()

        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.entry, .reviewDefaults)
        XCTAssertEqual(model.sharingState.replyBackTitle, "Share your Margins with Ana")
        XCTAssertEqual(model.sharingState.drafts.count, 1, "only the listener's own Margin is in the sheet, never the friend's")
    }

    /// Margins made before the friend's packet came are not answers: the ordinary sheet opens, with no reply heading.
    func testMarginsFromBeforeTheFriendsPacketOpenTheOrdinarySheet() async throws {
        let model = modelWithMargins(1)
        try giveFriendMargin(model, itemId: "item-pill", importedAt: Date().addingTimeInterval(3600))

        let start = await model.itemShareStart()
        XCTAssertEqual(start, .share)
        model.openItemShareSheet()

        XCTAssertTrue(model.isSharingInterjectionsPresented)
        XCTAssertEqual(model.sharingState.entry, .reviewDefaults)
        XCTAssertNil(model.sharingState.replyBackTitle, "nothing here answers the friend")
        XCTAssertEqual(model.sharingState.drafts.count, 1)
    }
}
