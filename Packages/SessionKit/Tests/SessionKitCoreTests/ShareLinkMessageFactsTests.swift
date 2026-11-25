import Foundation
import SessionKit
import SessionKitSharing
import XCTest

/// The facts the sentence beside a share link reads (#5264) come from the real packet the link is made from: the item's
/// type, the Margins going and whether each is the sender's own voice, and whether there is an audio address or page.
/// Real packets: the builder writes each, the archive writes it and reads it back.
final class ShareLinkMessageFactsTests: XCTestCase {
    private var root: URL!
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("link-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEachItemTypeReadsBackFromItsPacket() throws {
        let items: [(String, SharedItemIdentity, Bool)] = [
            ("article", SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "An Article"), true),
            ("pasted text", SharedItemIdentity(itemType: .text, title: "Pasted"), false),
            ("public episode", SharedItemIdentity(
                itemType: .podcast, canonicalURL: "https://example.com/episode-12", title: "Episode 12",
                enclosureURL: "https://traffic.megaphone.fm/ABC1234567890.mp3"), true),
            ("episode with audio and no page", SharedItemIdentity(
                itemType: .podcast, title: "Episode 13", enclosureURL: "https://traffic.megaphone.fm/ABC1234567891.mp3"), true),
            ("episode with neither", SharedItemIdentity(itemType: .podcast, title: "Bundled"), false),
            ("pdf", SharedItemIdentity(itemType: .pdf, title: "A Paper"), false),
            ("epub", SharedItemIdentity(itemType: .epub, title: "A Book"), false),
            ("recording", SharedItemIdentity(itemType: .other, title: "A Recording"), false)
        ]
        for (name, item, hasAudioOrPage) in items {
            let read = try readBack(item: item, representations: [.textOnly], name: name)
            XCTAssertEqual(read.facts.itemType, item.itemType, name)
            XCTAssertEqual(read.facts.hasAudioOrPage, hasAudioOrPage, name)
            XCTAssertEqual(read.facts.notes, ShareLinkMessage.Notes(count: 1, allVoice: false), name)
            XCTAssertEqual(read.facts.hasAudioOrPage, item.enclosureURL != nil || read.preview.source.url != nil, name)
        }
    }

    func testTheMarginsGoingGiveTheNoun() throws {
        let audio = root.appendingPathComponent("voice.m4a")
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: 6, count: 600)).write(to: audio)
        let voice = ReviewedRepresentationSelection.originalAudio(sourceURL: audio, durationMs: 600)
        let article = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "An Article")

        let rows: [(String, [ReviewedRepresentationSelection], ShareLinkMessage.Notes)] = [
            ("one voice", [voice], .init(count: 1, allVoice: true)),
            ("three voice", [voice, voice, voice], .init(count: 3, allVoice: true)),
            ("one written", [.textOnly], .init(count: 1, allVoice: false)),
            ("mixed", [voice, .textOnly, voice], .init(count: 3, allVoice: false))
        ]
        for (name, representations, expected) in rows {
            let read = try readBack(item: article, representations: representations, name: name.replacingOccurrences(of: " ", with: "-"))
            XCTAssertEqual(read.facts.notes, expected, name)
        }
        // The sentence the sender gets for the mixed article: plural, words, and no browser promise while unchecked.
        let mixed = try readBack(item: article, representations: [voice, .textOnly], name: "two-mixed")
        let item = ShareLinkMessage.SharedKind(itemType: mixed.facts.itemType, isSpokenNote: false)
        XCTAssertEqual(
            ShareLinkMessage.chooseSentence(item: item, notes: mixed.facts.notes, hasAudioOrPage: mixed.facts.hasAudioOrPage, playability: .unknown),
            "I left you notes on an article. You'll need Spoken Margins on iPhone to hear them with the article. The link shows what they're on and how to get the app."
        )
    }

    /// The preview read beside the facts is the one `preview(ofPackageAt:)` gives, so the link's page is unchanged.
    func testThePreviewIsTheSameAsBefore() throws {
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "An Article")
        let url = try packet(item: item, representations: [.textOnly], name: "same")
        let read = try ShareLinkPacketPreview.read(ofPackageAt: url, scratch: root.appendingPathComponent("a"))
        let alone = try ShareLinkPacketPreview.preview(ofPackageAt: url, scratch: root.appendingPathComponent("b"))
        XCTAssertEqual(read.preview, alone)
    }

    private func readBack(
        item: SharedItemIdentity, representations: [ReviewedRepresentationSelection], name: String
    ) throws -> (preview: ShareLinkPreview, facts: ShareLinkMessage.Facts) {
        let url = try packet(item: item, representations: representations, name: name)
        return try ShareLinkPacketPreview.read(ofPackageAt: url, scratch: root.appendingPathComponent("assets-\(name)"))
    }

    private func packet(item: SharedItemIdentity, representations: [ReviewedRepresentationSelection], name: String) throws -> URL {
        let selections = representations.enumerated().map { index, representation in
            ReviewedInterjectionSelection(
                packageScopedId: String(format: "margin-%04d", index + 1),
                revision: InterjectionShareRevision(
                    id: "revision-\(index)", interjectionId: "ij-\(index)", itemId: "item", sessionId: "session",
                    createdAt: createdAt.addingTimeInterval(Double(index)), approvedTranscript: "Thought \(index + 1).",
                    anchorBefore: "Before.", anchorAfter: "After.", status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 600_000 + index * 1_000),
                representation: representation
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "facts-\(name)", createdAt: createdAt, item: item,
            itemTransportSelection: .reference, selections: selections
        )
        let url = root.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-")).spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        return url
    }
}
