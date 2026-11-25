import SessionKit
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
        XCTAssertEqual(decide(), .lookUp(address: "https://thezvi.substack.com/p/gemini-4", route: .substack))
    }

    func testAPostOnACustomDomainWithASubstackPostPathIsLookedUp() {
        XCTAssertEqual(decide(address: "https://www.astralcodexten.com/p/some-post"), .lookUp(address: "https://www.astralcodexten.com/p/some-post", route: .substack))
    }

    func testEachReasonToSkipNamesItself() {
        XCTAssertEqual(decide(looked: true), .skip(reason: "already_looked_up"))
        XCTAssertEqual(decide(textCharacters: nil), .skip(reason: "no_text"))
        XCTAssertEqual(decide(textCharacters: 0), .skip(reason: "no_text"))
        XCTAssertEqual(decide(address: nil), .skip(reason: "no_address"))
        XCTAssertEqual(decide(address: ""), .skip(reason: "no_address"))
        XCTAssertEqual(decide(address: "https://example.com/articles/one"), .skip(reason: "not_substack_address"), "an import never takes the article feed route")
        XCTAssertEqual(decide(address: "http://thezvi.substack.com/p/one"), .skip(reason: "not_substack_address"), "https only")
        XCTAssertEqual(decide(record: true), .skip(reason: "has_record"))
    }

    func testAnEarlierLookupWinsOverEveryOtherReason() {
        XCTAssertEqual(decide(textCharacters: nil, address: nil, record: true, looked: true), .skip(reason: "already_looked_up"))
    }

    // MARK: The article feed route (#4640)

    private func onOpen(_ address: String?, trigger: VoiceoverLookupDecision.Trigger = .open, mediaType: String = "text",
                        referenceType: String? = nil, itemId: String = "item-1", record: Bool = false, followed: Bool = false) -> VoiceoverLookupDecision {
        .decide(textCharacterCount: 5_000, externalReference: address, hasPublisherAudioRecord: record, alreadyLookedUp: false,
                trigger: trigger, mediaType: mediaType, externalReferenceType: referenceType, itemId: itemId, siteIsFollowed: followed)
    }

    func testTheRouteForEachAddress() {
        let openai = "https://openai.com/index/managing-frontier-ai-risk/"
        XCTAssertEqual(onOpen("https://thezvi.substack.com/p/gemini-4"), .lookUp(address: "https://thezvi.substack.com/p/gemini-4", route: .substack))
        XCTAssertEqual(onOpen("https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x"), .lookUp(address: "https://www.lesswrong.com/posts/WQFioaudEH8R7fyhm/x", route: .typeIII))
        XCTAssertEqual(onOpen(openai), .lookUp(address: openai, route: .articleFeed))
        XCTAssertEqual(onOpen(openai, trigger: .play), .lookUp(address: openai, route: .articleFeed))
        XCTAssertEqual(onOpen(openai, trigger: .importing), .skip(reason: "not_substack_address"), "never at import")
        XCTAssertEqual(onOpen("https://example.com/articles/one"), .lookUp(address: "https://example.com/articles/one", route: .articleFeed))
        XCTAssertEqual(onOpen(openai, trigger: .queueAdvance), .skip(reason: "not_substack_address"), "the queue moving on by itself is not the listener's action")
    }

    /// A `/p/` page on a site that isn't Substack is read as a Substack post first; on the listener's open or play its
    /// own feed gets a chance when the page has no Substack data (Default 10 of the #4640 Design).
    func testAPostPathPageOffSubstackMayEndOnItsFeed() {
        let essay = "https://example.org/p/essay"
        XCTAssertEqual(onOpen(essay), .lookUp(address: essay, route: .postPageThenArticleFeed))
        XCTAssertEqual(onOpen(essay, trigger: .play), .lookUp(address: essay, route: .postPageThenArticleFeed))
        XCTAssertEqual(onOpen("https://www.astralcodexten.com/p/some-post"), .lookUp(address: "https://www.astralcodexten.com/p/some-post", route: .postPageThenArticleFeed))
        XCTAssertEqual(onOpen(essay, trigger: .importing), .lookUp(address: essay, route: .substack), "never the feed at import")
        XCTAssertEqual(onOpen(essay, trigger: .queueAdvance), .lookUp(address: essay, route: .substack))
        XCTAssertEqual(onOpen(essay, followed: true), .lookUp(address: essay, route: .substack), "a followed site's feed already imported its audio")
        XCTAssertEqual(onOpen("https://thezvi.substack.com/p/gemini-4"), .lookUp(address: "https://thezvi.substack.com/p/gemini-4", route: .substack), "Substack's own pages keep its route")
        XCTAssertEqual(onOpen("https://SUBSTACK.com/p/x"), .lookUp(address: "https://SUBSTACK.com/p/x", route: .substack))
        XCTAssertTrue(VoiceoverLookupDecision.Route.postPageThenArticleFeed.mayUseArticleFeed)
        XCTAssertTrue(VoiceoverLookupDecision.Route.articleFeed.mayUseArticleFeed)
        XCTAssertFalse(VoiceoverLookupDecision.Route.substack.mayUseArticleFeed)
        XCTAssertFalse(VoiceoverLookupDecision.Route.typeIII.mayUseArticleFeed)
    }

    func testTheArticleFeedRouteSkips() {
        let openai = "https://openai.com/index/managing-frontier-ai-risk/"
        XCTAssertEqual(onOpen(openai, followed: true), .skip(reason: "not_substack_address"), "a followed site's feed already imported its audio")
        XCTAssertEqual(onOpen("http://openai.com/index/x"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(onOpen(openai, mediaType: "pdf"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(onOpen(openai, mediaType: "podcast"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(onOpen(openai, referenceType: "file"), .skip(reason: "not_substack_address"))
        XCTAssertEqual(onOpen(openai, itemId: ListeningEdition.itemIDPrefix + "x"), .skip(reason: "not_substack_address"), "a Listening Edition")
        XCTAssertEqual(onOpen(openai, record: true), .skip(reason: "has_record"))
    }
}
