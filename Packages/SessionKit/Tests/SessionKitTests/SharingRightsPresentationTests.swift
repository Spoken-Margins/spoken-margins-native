import Foundation
import SessionKit
import SessionKitSharing
import XCTest

/// The words a sender and a recipient are shown about rights, chosen from a packet that was really written and read
/// back (#318: the type moved here from the app, with no change to its copy). Each test names the branch it covers.
final class SharingRightsPresentationTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_777_000_000)

    private func revision(before: String = "Before this passage.", after: String = "After this passage.") -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
            cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
            anchorBefore: before, anchorAfter: after, status: .senderApproved
        )
    }

    private func disclosures(
        item: SharedItemIdentity,
        transport: ReviewedItemTransportSelection = .reference,
        anchor: PortableAnchorEvidence = .init(anchorType: .text, exactText: "The exact words."),
        contextBefore: String = "Before this passage.",
        contextAfter: String = "After this passage."
    ) throws -> [String] {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "rights-package", createdAt: fixedDate, item: item, itemTransportSelection: transport,
            selections: [.init(packageScopedId: "margin-001", revision: revision(before: contextBefore, after: contextAfter), anchor: anchor, representation: .textOnly)]
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharingRightsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rights.spokenmargins")
        _ = try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        return SharingRightsPresentation.disclosures(for: verified)
    }

    private var article: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    func testEveryPacketStartsWithTheTwoNoticesAndTheFixedLines() throws {
        let lines = try disclosures(item: article)
        XCTAssertEqual(Array(lines.prefix(2)), [SharingRightsPresentation.rightsNotice, SharingRightsPresentation.recipientCopiesNotice])
        XCTAssertTrue(lines.contains("Source audio and full generated podcast transcripts are not included."))
        XCTAssertTrue(lines.contains("Sender identity is labeled but not cryptographically verified."))
        XCTAssertTrue(SharingRightsPresentation.rightsNotice.contains("Attribution, a short excerpt, or a private recipient does not by itself grant permission."))
        XCTAssertTrue(SharingRightsPresentation.recipientCopiesNotice.contains("Deleting your local copy cannot revoke their copies."))
    }

    func testAttributionLinesAppearOnlyForFieldsThePacketHolds() throws {
        let lines = try disclosures(item: article)
        XCTAssertTrue(lines.contains("Title: A Useful Article"))
        XCTAssertTrue(lines.contains("Source reference: https://example.com/article"))
        for absent in ["Author:", "Publisher:", "Show:", "Published:", "Episode reference:", "Media reference:", "Feed reference:", "Language:", "Source duration:"] {
            XCTAssertFalse(lines.contains { $0.hasPrefix(absent) }, absent)
        }
        XCTAssertFalse(lines.contains { $0.contains("fingerprints") })
    }

    func testAPodcastNamesItsShowFeedAndDuration() throws {
        let podcast = SharedItemIdentity(
            itemType: .podcast, canonicalURL: "https://example.com/episodes/one",
            title: "Episode One", publisher: "Example", showTitle: "Example Show", episodeGUID: "episode-one",
            enclosureURL: "https://example.com/audio/one.mp3", durationMs: 3_600_000, languageCode: "en",
            source: SharedSourceIdentity(
                sourceType: .podcastFeed, canonicalURL: "https://example.com/feed.xml", title: "Example Show", publisher: "Example"
            )
        )
        let lines = try disclosures(item: podcast, anchor: .init(anchorType: .media, mediaTimeMs: 401_000))
        for expected in [
            "Show: Example Show", "Publisher: Example", "Episode reference: episode-one",
            "Media reference: https://example.com/audio/one.mp3", "Feed reference: https://example.com/feed.xml",
            "Feed title: Example Show", "Feed publisher: Example", "Language: en", "Source duration: 3600 seconds.",
            "The recipient acquires the referenced source separately."
        ] {
            XCTAssertTrue(lines.contains(expected), expected)
        }
    }

    func testEmbeddedTextSaysItIsTheFullListenedToTextAndFingerprintsAreNamed() throws {
        let text = "A linkless item whose exact listened-to text can travel with reviewed Margins."
        let item = SharedItemIdentity(
            itemType: .pdf, title: "Linkless Reading",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let lines = try disclosures(
            item: item,
            transport: .embeddedText(text: text, originalMediaType: "pdf", rightsBasis: .senderConfirmedPrivateRights)
        )
        XCTAssertTrue(lines.contains("Complete source text included: \(text.count) characters. This is the full listened-to text, not just the words around each Margin."))
        XCTAssertTrue(lines.contains("Source-content fingerprints are included to identify the supplied edition."))
    }

    func testARecipientSuppliedSourceIsSaidToBeOmitted() throws {
        let text = "A linkless item whose exact listened-to text can travel with reviewed Margins."
        let item = SharedItemIdentity(
            itemType: .pdf, title: "Linkless Reading",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let lines = try disclosures(item: item, transport: .recipientSupplied)
        XCTAssertTrue(lines.contains("The source is omitted; the recipient must supply the same one."))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Complete source text included") })
    }

    func testAMarginListsItsContextAndHowItWasApproved() throws {
        // The packet takes a Margin's context from its reviewed revision, not from the anchor it was captured with.
        let lines = try disclosures(
            item: article,
            anchor: .init(anchorType: .text, exactText: "The exact words.", chapterTitle: "Chapter One"),
            contextBefore: "Words before.", contextAfter: "Words after."
        )
        for expected in [
            "Margin 1 includes its creation time and reviewed representation provenance.",
            "Margin 1 — Exact excerpt: The exact words.", "Margin 1 — Chapter: Chapter One",
            "Margin 1: sender-approved text only; no recording."
        ] {
            XCTAssertTrue(lines.contains(expected), expected)
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("Margin 1 — Context before: ") && $0.contains("before") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Margin 1 — Context after: ") && $0.contains("after") })
    }

    func testEmptyContextExcerptAndChapterAreNotListed() throws {
        let bare = try disclosures(item: article, anchor: .init(anchorType: .text), contextBefore: "", contextAfter: "")
        for absent in ["— Context before:", "— Context after:", "— Exact excerpt:", "— Chapter:"] {
            XCTAssertFalse(bare.contains { $0.contains(absent) }, absent)
        }
        XCTAssertTrue(bare.contains("Margin 1: sender-approved text only; no recording."))
    }

    func testMatchingEvidenceIsCountedAndNoGeneratedVoiceLineAppearsWithoutVoiceAssets() throws {
        let lines = try disclosures(item: article)
        XCTAssertTrue(lines.contains("Matching evidence: 0 acoustic signatures and 0 edition maps. These are matching evidence, not playable source audio or proof of permission."))
        XCTAssertTrue(lines.contains("Text-derived matching evidence: 0 phrase sketches. Acoustic opt-out is separate from this text-derived evidence."))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Generated or summary voice assets included") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("Listening Map") })
    }
}
