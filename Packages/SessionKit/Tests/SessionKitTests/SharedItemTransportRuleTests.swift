import SessionKit
import SessionKitSharing
import XCTest

/// #2997: a meeting transcript is never embedded in a packet, whatever the sender confirms.
final class SharedItemTransportRuleTests: XCTestCase {
    private func item(referenceType: String?, text: String? = "Priya Patel: Thanks for joining.") -> Item {
        Item(id: "item", title: "Budget sync", mediaType: "text", text: text, externalReference: "sync.vtt", status: "ready",
             externalReferenceType: referenceType)
    }

    func testOnlyATranscriptIsRefusedEmbedding() {
        for type in [nil, "", "file", "url", "paste", "pdf", "epub", "TRANSCRIPT", "transcript "] as [String?] {
            XCTAssertTrue(SharedItemTransportRule.allowsEmbeddedText(item(referenceType: type)), "\(type ?? "nil") may embed")
        }
        XCTAssertFalse(SharedItemTransportRule.allowsEmbeddedText(item(referenceType: TranscriptItemText.referenceType)))
        XCTAssertFalse(SharedItemTransportRule.allowsEmbeddedText(externalReferenceType: "transcript"))
    }

    func testTheBackstopKeepsATranscriptRecipientSuppliedForEveryRightsChoice() {
        let identity = SharedItemIdentity(itemType: .text, title: "Budget sync")
        for authored in [false, true] {
            for rights in [false, true] {
                let transport = SharedMarginExport.itemTransport(
                    item: item(referenceType: TranscriptItemText.referenceType), identity: identity,
                    isAppAuthored: authored, confirmsPrivateRights: rights)
                guard case .recipientSupplied = transport else {
                    XCTFail("A transcript must not embed: authored \(authored), rights \(rights)"); continue
                }
            }
        }
    }

    func testAnOrdinaryTextFileStillEmbedsWhenTheSenderConfirmsRights() {
        let identity = SharedItemIdentity(itemType: .text, title: "Essay")
        for type in [nil, "file"] as [String?] {
            let transport = SharedMarginExport.itemTransport(
                item: item(referenceType: type, text: "An essay."), identity: identity, isAppAuthored: false, confirmsPrivateRights: true)
            guard case .embeddedText(let text, _, let basis) = transport else { XCTFail("Expected embedded text"); continue }
            XCTAssertEqual(text, "An essay.")
            XCTAssertEqual(basis, .senderConfirmedPrivateRights)
        }
    }

    func testALinkStillWinsOverTheTranscriptRule() {
        // A transcript has no web address, but the rule must not change what a link does.
        let transport = SharedMarginExport.itemTransport(
            item: item(referenceType: TranscriptItemText.referenceType),
            identity: .init(itemType: .text, canonicalURL: "https://example.com/meeting", title: "Budget sync"),
            isAppAuthored: false, confirmsPrivateRights: true)
        guard case .reference = transport else { XCTFail("A link wins"); return }
    }
}
