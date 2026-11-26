import Foundation
import XCTest
@testable import SessionKit

/// #3777: the iOS voice takes the article over while a note is being read (a memory warning, a stalled player, a
/// background seam). The client starts the iOS voice at the source offset of the place it reports, which while a note
/// reads is the note's own offset, the citing sentence's end (`SupertonicSpeechPlaybackClient.currentCharOffset`: an
/// aside has no source characters, so its place is its start), mapped through the player's projection, the one with the
/// citations silent. The iOS voice then reads the plain text from that source offset, with the markers spoken and the
/// notes in their chapter at the end (`SpeechTextNormalizer.projectForSystemSpeech(_:fromSourceOffset:)`, what
/// `SystemSpeechPlaybackClient.play(targetId:from:)` plans from).
///
/// What the listener hears then is pinned here from the real planner and both normalizers, with and without a preface
/// before the article: the iOS voice goes on with the sentence after the citing one (it does not replay the citing
/// sentence), and the note it cannot read in place is still in what it reads, in the notes chapter at the end. The iOS
/// voice has no aside chunks (`hasFootnoteAsides` is false under it), so this is the "Read at the end" behaviour of the
/// Design, Flow 7. Not covered: the client's own wiring, which needs the app target.
final class FootnoteSystemVoiceHandOverTests: XCTestCase {
    private typealias Planner = NarrationChunkPlanner

    private static let preface = "Overview. A short piece about the tide and the boats that wait for it.\n\n"

    /// What the iOS voice reads, from where the client would start it for a hand-over while the note at `noteIndex`
    /// (counted among the plan's asides) is the chunk playing. The plan is the player's own (`spokenPlan`), so a preface
    /// shifts every offset as it does in the app.
    private func iosVoiceRemainder(article: String, noteIndex: Int, preface: String) throws -> String {
        let source = preface + article
        let ranges = Planner.silencedCitationRanges(inArticle: article)
            .map { ($0.lowerBound + preface.count)..<($0.upperBound + preface.count) }
        let silenced = SpeechTextNormalizer.normalizeWithSourceOffsets(source, silencingSourceRanges: ranges)
        let start = silenced.spokenCharacterOffset(atOrAfterSourceOffset: preface.count)
        let plan = Planner.spokenPlan(spokenText: silenced.text, articleText: article, articleSpokenStart: start, asides: true)
        let asides = plan.chunks.filter { if case .aside = $0.footnote { true } else { false } }
        let note = try XCTUnwrap(asides.indices.contains(noteIndex) ? asides[noteIndex] : nil)
        let reported = silenced.sourceOffset(atSpokenCharacterOffset: note.startOffset)
        return SpeechTextNormalizer.projectForSystemSpeech(source, fromSourceOffset: reported).text
    }

    private func asideCount(_ article: String) -> Int {
        Planner.articlePlan(article, asides: true).chunks.filter { if case .aside = $0.footnote { true } else { false } }.count
    }

    private struct Row {
        let name: String
        let article: String
        /// The text the iOS voice must go on with, per aside in plan order.
        let continuesWith: [String]
        /// The note text each aside carries, which must still be read after the hand-over.
        let stillRead: [String]
    }

    private let rows = [
        Row(name: "a note mid-article",
            article: "The tide turns twice a day.[^1] It rests between turns. Boats wait for it.[^2] Then they leave.\n\n[^1]: Smith, Tides, 2020.\n[^2]: Lee, Boats, 2021.",
            continuesWith: ["It rests between turns.", "Then they leave."],
            stillRead: ["Smith, Tides, 2020", "Lee, Boats, 2021"]),
        Row(name: "two notes cited in one sentence",
            article: "Tides turn twice a day.[^a][^b] They rest between turns.\n\n[^a]: First note.\n[^b]: Second note.",
            continuesWith: ["They rest between turns.", "They rest between turns."],
            stillRead: ["First note", "Second note"]),
        Row(name: "no space after the marker",
            article: "Tides turn twice a day.[^1]They rest between turns.\n\n[^1]: A note.",
            // With no space after it, the marker's own word is the first thing the plain voice says; the citing
            // sentence is still not replayed.
            continuesWith: ["footnote 1 They rest between turns."],
            stillRead: ["A note"]),
        Row(name: "a marker inside the sentence",
            article: "Tides[^1] turn twice a day. They rest between turns.\n\n[^1]: A note.",
            continuesWith: ["They rest between turns."],
            stillRead: ["A note"]),
        // The cut falls after the marker, so the only thing left to read is the notes chapter, which holds the note
        // under its own label.
        Row(name: "a note in the last sentence",
            article: "Tides turn twice a day. They rest between turns.[^1]\n\n[^1]: A closing note.",
            continuesWith: ["footnote 1 : A closing note"],
            stillRead: ["A closing note"]),
        Row(name: "a note followed by a new paragraph",
            article: "Tides turn twice a day.[^1]\n\nThey rest between turns.\n\n[^1]: A note.",
            continuesWith: ["They rest between turns."],
            stillRead: ["A note"]),
    ]

    func testAHandOverDuringANoteGoesOnAfterTheCitingSentenceAndTheNoteStaysInWhatItReads() throws {
        for row in rows {
            XCTAssertEqual(asideCount(row.article), row.continuesWith.count, "\(row.name): one aside per note")
            for preface in ["", Self.preface] {
                let label = "\(row.name)\(preface.isEmpty ? "" : " after a preface")"
                for n in row.continuesWith.indices {
                    let remainder = try iosVoiceRemainder(article: row.article, noteIndex: n, preface: preface)
                    XCTAssertTrue(
                        remainder.hasPrefix(row.continuesWith[n]),
                        "\(label), note \(n + 1): the iOS voice goes on with \(row.continuesWith[n]), not \(remainder.prefix(40))")
                    XCTAssertFalse(remainder.hasPrefix("Tide"), "\(label), note \(n + 1): the citing sentence is not replayed")
                    XCTAssertTrue(
                        remainder.contains(row.stillRead[n]),
                        "\(label), note \(n + 1): the note is still read, in the notes chapter at the end")
                }
            }
        }
    }
}
