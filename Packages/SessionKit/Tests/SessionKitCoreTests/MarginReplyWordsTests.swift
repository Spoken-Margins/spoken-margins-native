import Foundation
import SessionKit
import XCTest

/// #3890: what the reply composer says about the Margin being answered, in plain words.
final class MarginReplyWordsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    private func layer(label: String?) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: String(repeating: "a", count: 64), packageId: "pkg",
            itemIdentity: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A"),
            displayLabel: label, importedAt: t0
        )
        layer.isEnabled = true
        return layer
    }

    private func parent(text: String, timeMs: Int?) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "m1", layerId: "layer", packageScopedId: "m1-scoped", createdAt: t0,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: timeMs), approvedTranscript: text,
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 1_000)
        )
    }

    private func caption(label: String?, text: String, timeMs: Int?) -> String {
        MarginReplyDraft(parent: parent(text: text, timeMs: timeMs), in: layer(label: label)).caption
    }

    private let stand = "Voice Margin at 1:45 in \u{201C}More Perfect: Cruel and Unusual\u{201D}, recorded 9 Nov 2026"

    /// The table from the design: who is named, and words versus no words.
    func testTheCaptionForEveryCombinationOfNameAndWords() {
        let rows: [(label: String?, text: String, timeMs: Int?, caption: String)] = [
            ("Sam", "The author never says why.", 105_000, "Replying to Sam: \u{201C}The author never says why.\u{201D}"),
            ("Sam", stand, 105_000, "Replying to Sam's Margin at 1:45"),
            ("Sam", "", 105_000, "Replying to Sam's Margin at 1:45"),
            ("Sam", stand, nil, "Replying to Sam's Margin"),
            (nil, stand, 105_000, "Replying to a friend's Margin at 1:45"),
            ("", stand, 105_000, "Replying to a friend's Margin at 1:45"),
            (MarginLayerSynthesis.unnamedSenderLabel, stand, 105_000, "Replying to a friend's Margin at 1:45"),
            (MarginLayerSynthesis.unnamedSenderLabel, "Why not?", 105_000, "Replying to a friend: \u{201C}Why not?\u{201D}"),
            ("someone", "Why not?", nil, "Replying to a friend: \u{201C}Why not?\u{201D}"),
            (SharedPacketArrival.unsignedSenderLabel, "Why not?", nil, "Replying to a friend: \u{201C}Why not?\u{201D}"),
            ("Sam", stand, 3_725_000, "Replying to Sam's Margin at 1:02:05"),
            ("Sam", stand, 0, "Replying to Sam's Margin at 0:00"),
            ("Sam", stand, -5, "Replying to Sam's Margin"),
        ]
        for row in rows {
            XCTAssertEqual(caption(label: row.label, text: row.text, timeMs: row.timeMs), row.caption, "\(row)")
        }
    }

    /// The row's accessibility text, the stand-in's pieces and nested quotes never reach the caption.
    func testNeighbouringTextsNeverNestQuotesOrShowTheStandIn() {
        let rows: [(text: String, expected: String)] = [
            ("He said \u{201C}no\u{201D} twice.", "Replying to Sam: \u{201C}He said \u{2018}no\u{2019} twice.\u{201D}"),
            ("He said \"no\" twice.", "Replying to Sam: \u{201C}He said 'no' twice.\u{201D}"),
            ("  two\n\nlines\t here  ", "Replying to Sam: \u{201C}two lines here\u{201D}"),
            ("Voice Margin at 1:45 is where she turns.", "Replying to Sam: \u{201C}Voice Margin at 1:45 is where she turns.\u{201D}"),
            ("voice margin at 1:45", "Replying to Sam: \u{201C}voice margin at 1:45\u{201D}"),
            ("Voice Margin at 1:45 in \u{201C}A\u{201D}, recorded 9 Nov 2026 and more", "Replying to Sam: \u{201C}Voice Margin at 1:45 in \u{2018}A\u{2019}, recorded 9 Nov 2026 and more\u{201D}"),
            ("\u{00C9}t\u{00E9} \u{1F600} caf\u{00E9}", "Replying to Sam: \u{201C}\u{00C9}t\u{00E9} \u{1F600} caf\u{00E9}\u{201D}"),
        ]
        for row in rows {
            let text = caption(label: "Sam", text: row.text, timeMs: 105_000)
            XCTAssertEqual(text, row.expected, row.text)
            XCTAssertFalse(text.contains("\u{201C}\u{201C}") || text.contains("\u{201D}\u{201D}"))
        }
    }

    func testALongExcerptIsCutAtNinetyCharactersWithAnEllipsis() {
        let exactly = String(repeating: "a", count: 90)
        XCTAssertEqual(MarginReplyWords.excerpt(of: exactly), exactly, "90 characters is kept whole")
        XCTAssertEqual(MarginReplyWords.excerpt(of: exactly + "b"), exactly + "…")
        let spaced = String(repeating: "word ", count: 60)
        let cut = try? XCTUnwrap(MarginReplyWords.excerpt(of: spaced))
        XCTAssertEqual(cut, String(repeating: "word ", count: 17) + "word…", "no space before the ellipsis")
        let emoji = String(repeating: "\u{1F600}", count: 100)
        XCTAssertEqual(MarginReplyWords.excerpt(of: emoji), String(repeating: "\u{1F600}", count: 90) + "…", "cut at a whole character")
        XCTAssertNil(MarginReplyWords.excerpt(of: " \n\t "))
        XCTAssertNil(MarginReplyWords.excerpt(of: ""))
        XCTAssertNil(MarginReplyWords.excerpt(of: "\u{200B}\u{FEFF} "), "invisible characters are no words")
    }

    func testNamesAndPossessivesForNamedAndNamelessSenders() {
        XCTAssertEqual(MarginReplyWords.name("Sam"), "Sam")
        XCTAssertEqual(MarginReplyWords.name("  Sam  "), "Sam")
        XCTAssertEqual(MarginReplyWords.possessive("Sam"), "Sam's")
        XCTAssertEqual(MarginReplyWords.heading("Sam"), "Sam")
        for label in [nil, "", " ", "Someone", " someone ", "SOMEONE", "Unsigned sender", "Imported collection"] as [String?] {
            XCTAssertEqual(MarginReplyWords.name(label), "a friend", "\(label ?? "nil")")
            XCTAssertEqual(MarginReplyWords.possessive(label), "a friend's")
            XCTAssertEqual(MarginReplyWords.heading(label), "A friend")
        }
        XCTAssertEqual(MarginReplyWords.name("Someone Else"), "Someone Else", "a name that starts with the stand-in is a name")
        XCTAssertEqual(MarginLayerSynthesis.unnamedSenderLabel, "Someone", "the stored label does not change")
    }

    func testTheClockIsThePlayersClock() {
        XCTAssertEqual(MarginReplyWords.clock(milliseconds: 105_000), "1:45")
        XCTAssertEqual(MarginReplyWords.clock(milliseconds: 599_999), "9:59")
        XCTAssertEqual(MarginReplyWords.clock(milliseconds: 3_600_000), "1:00:00")
        XCTAssertEqual(MarginReplyWords.clock(milliseconds: -1), "0:00")
    }

    /// The stand-in shapes the senders write: with and without each part, a title with quotes in it, and a long clock.
    func testTheStandInIsRecognisedForEveryPartCombinationAndNothingElse() {
        let accepted = [
            "Voice Margin",
            "Voice Margin at 1:45",
            "Voice Margin at 12:34",
            "Voice Margin at 105:09",
            "Voice Margin at 1:02:05",
            "Voice Margin in \u{201C}Title\u{201D}",
            "Voice Margin, recorded 9 Nov 2026",
            "Voice Margin at 1:45, recorded 30 Oct 2026",
            "Voice Margin at 1:45 in \u{201C}Title\u{201D}",
            "Voice Margin at 1:45 in \u{201C}A \u{201C}quoted\u{201D} title\u{201D}, recorded 9 Nov 2026",
            "Voice Margin at 1:45 in \u{201C}\u{201D}, recorded 9 Nov 2026",
            "  Voice Margin at 1:45 \n",
        ]
        for text in accepted { XCTAssertTrue(SharedMarginPlaceholderWords.matches(text), text) }
        let rejected = [
            "", "Voice", "voice margin at 1:45", "Voice Margins at 1:45", "Voice Margin at 1:4", "Voice Margin at :45",
            "Voice Margin at 1:45 in Title", "Voice Margin at 1:45 in \"Title\"", "Voice Margin at 1:45, recorded 9 November 2026",
            "Voice Margin at 1:45, recorded 9 Nov", "Voice Margin recorded 9 Nov 2026", "Voice Margin at 1:45!",
            "My Voice Margin at 1:45", "Voice Margin at 1:45\nand a second line", "Voice Margin at 1:45 is the part I mean",
        ]
        for text in rejected { XCTAssertFalse(SharedMarginPlaceholderWords.matches(text), text) }
    }
}
