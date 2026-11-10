import XCTest
@testable import SpokenMarginsApp

/// #3849: the record button's drawn words were not in its accessible name, so a spoken "Tap Add a Margin" could miss it.
final class MarginRecordNamesTests: XCTestCase {
    func testVoiceControlCanReachTheButtonByItsDrawnWordsAtEveryTextSize() {
        for accessibilitySize in [false, true] {
            let drawn = MarginRecordNames.visible(accessibilitySize: accessibilitySize)
            XCTAssertTrue(MarginRecordNames.inputLabels.contains(drawn),
                          "\"\(drawn)\" is drawn on the button but Voice Control has no label for it")
        }
    }

    func testVoiceOverKeepsItsClearName() {
        XCTAssertEqual(MarginRecordNames.spoken, "Record a Margin")
        XCTAssertTrue(MarginRecordNames.inputLabels.contains(MarginRecordNames.spoken),
                      "someone who learned the VoiceOver name can still say it")
    }

    func testTheFirstInputLabelIsTheDefaultSizeWords() {
        XCTAssertEqual(MarginRecordNames.inputLabels.first, "Add a Margin")
    }
}
