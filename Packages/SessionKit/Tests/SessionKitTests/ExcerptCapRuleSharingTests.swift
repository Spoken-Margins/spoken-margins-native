import XCTest
@testable import SessionKit
import SessionKitSharing

/// The link draft and the packet use the same excerpt cap rule (#2237). The rule's own table is in
/// SessionKitCoreTests/ExcerptCapRuleTests, which also runs on Linux.
final class ExcerptCapRuleSharingTests: XCTestCase {
    private let words = String(repeating: "alpha beta gamma ", count: 80)

    func testAPacketAndALinkDraftBuiltFromTheSameMarginCarryTheSameContext() {
        let margin = Interjection(
            id: "margin", itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 0, anchorBefore: words, anchorAfter: words),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "A short thought about this.",
            cleanedTranscript: nil, displayText: nil, status: "active"
        )
        let draft = ShareDraft(scope: .margin(id: "margin"), candidates: [margin])
        let quote = draft.moments[0].quote
        let evidence = PortableAnchorEvidence(anchorType: .text, startChar: 0, endChar: 0, prefix: words, suffix: words)
            .bounded(commentLength: ExcerptCapRule.commentLength(transcript: "A short thought about this."))
        XCTAssertEqual(evidence.prefix, quote.before)
        XCTAssertEqual(evidence.suffix, quote.after)
        XCTAssertLessThanOrEqual(quote.after.count, 120)
    }
}
