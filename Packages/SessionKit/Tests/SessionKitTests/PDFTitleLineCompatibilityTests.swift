import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest

/// #2062: Build 34 read a PDF's placeholder metadata title ("Microsoft Word - report.docx") as the first line of
/// the PDF's text. A newer build leaves that line out, so the same PDF's text no longer hashes the same.
final class PDFTitleLineCompatibilityTests: XCTestCase {
    private let body = "We measured sleep in adults and found a steady effect."

    private func pdf(id: String, title: String, text: String) -> Item {
        Item(id: id, title: title, mediaType: "pdf", text: text, externalReference: "shared-file://share-sheet/report.pdf", status: "ready")
    }

    /// ACCEPTED MISS (owner decision pending). A local PDF with no https address has only its text hash to be
    /// matched by. A packet from a Build-34 listener carries the hash of the text with the placeholder line; the
    /// new build's text lacks that line, so the packet finds no item and import adds a copy. This pins today's
    /// behaviour: if it starts matching (or a different outcome), a later change moved packet matching and the
    /// owner-data check must be redone.
    func testAcceptedMissBuild34PlaceholderLinePacketDoesNotFindTheNewBuildsLocalPDF() {
        let sender = pdf(id: "sender", title: "Microsoft Word - report.docx", text: "Microsoft Word - report.docx\n\(body)")
        let receiver = pdf(id: "receiver", title: "Report", text: body)
        let packetItem = SharedPacketItemMatcher.localIdentity(for: sender, ownedAudiobookDigest: nil)
        XCTAssertNil(SharedPacketItemMatcher.matchingItemId(for: packetItem, among: [receiver]))
    }

    /// The same PDF read by the same build matches, so the miss above is about the changed first line only.
    func testControlSameTextMatches() {
        let sender = pdf(id: "sender", title: "Report", text: body)
        let receiver = pdf(id: "receiver", title: "Report", text: body)
        let packetItem = SharedPacketItemMatcher.localIdentity(for: sender, ownedAudiobookDigest: nil)
        XCTAssertEqual(SharedPacketItemMatcher.matchingItemId(for: packetItem, among: [receiver]), "receiver")
    }
}
