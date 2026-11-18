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
}
