import SessionKitFeeds
import XCTest

/// #2789: one rule for "read this post's page for a voiceover?", used when the listener opens or starts an item.
final class VoiceoverLookupDecisionTests: XCTestCase {
    private func decide(
        textCharacters: Int? = 7,
        address: String? = "https://thezvi.substack.com/p/gemini-4",
        record: Bool = false,
        looked: Bool = false
    ) -> VoiceoverLookupDecision {
        .decide(textCharacterCount: textCharacters, externalReference: address, hasPublisherAudioRecord: record, alreadyLookedUp: looked)
    }

    func testASubstackPostWithNoRecordIsLookedUp() {
        XCTAssertEqual(decide(), .lookUp(address: "https://thezvi.substack.com/p/gemini-4"))
    }

    func testAPostOnACustomDomainWithASubstackPostPathIsLookedUp() {
        XCTAssertEqual(decide(address: "https://www.astralcodexten.com/p/some-post"), .lookUp(address: "https://www.astralcodexten.com/p/some-post"))
    }

    func testEachReasonToSkipNamesItself() {
        XCTAssertEqual(decide(looked: true), .skip(reason: "already_looked_up"))
        XCTAssertEqual(decide(textCharacters: nil), .skip(reason: "no_text"))
        XCTAssertEqual(decide(textCharacters: 0), .skip(reason: "no_text"))
        XCTAssertEqual(decide(address: nil), .skip(reason: "no_address"))
        XCTAssertEqual(decide(address: ""), .skip(reason: "no_address"))
        XCTAssertEqual(decide(address: "https://example.com/articles/one"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(decide(address: "http://thezvi.substack.com/p/one"), .skip(reason: "not_substack_address"), "https only")
        XCTAssertEqual(decide(record: true), .skip(reason: "has_record"))
    }

    func testAnEarlierLookupWinsOverEveryOtherReason() {
        XCTAssertEqual(decide(textCharacters: nil, address: nil, record: true, looked: true), .skip(reason: "already_looked_up"))
    }
}
