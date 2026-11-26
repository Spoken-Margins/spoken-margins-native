import Foundation
@testable import SessionKit
@testable import SessionKitSharing
import XCTest

/// #2997 PR 2b: the sharing side of `TranscriptReferenceTypeAuditTests` (it needs `SessionKitSharing`, which only the
/// Mac test target links). A transcript item is matched by its text like any text item.
final class TranscriptSharingIdentityTests: XCTestCase {
    private let body = "Ana: Hello there.\n\nBo: Hi."

    private var transcript: Item {
        Item(
            id: "item-transcript-1", title: "Budget sync", mediaType: "text", text: body,
            externalReference: "Budget sync.vtt", status: "needs_listening_map",
            externalReferenceType: TranscriptItemText.referenceType)
    }

    private var plainFile: Item {
        var item = transcript
        item.externalReferenceType = "file"
        return item
    }

    func testSharingMatchesATranscriptByItsTextLikeAnyTextItem() {
        XCTAssertEqual(SharedItemIdentityBuilder.itemType(for: transcript), SharedItemIdentityBuilder.itemType(for: plainFile))
        XCTAssertEqual(SharedItemIdentityBuilder.itemType(for: transcript), .text)
        XCTAssertTrue(SharedItemIdentityBuilder.isMatchedByItsText(transcript))
        XCTAssertEqual(
            SharedItemIdentityBuilder.localIdentity(for: transcript), SharedItemIdentityBuilder.localIdentity(for: plainFile),
            "same text, same digests, nothing about the reference type in the identity")
        XCTAssertNotNil(SharedItemIdentityBuilder.localIdentity(for: transcript).normalizedContentSHA256)
        XCTAssertNil(SharedItemIdentityBuilder.localIdentity(for: transcript).canonicalURL, "a file name is not an address")
    }
}
