import Foundation
import XCTest
@testable import SessionKit

/// #3777: the iOS voice takes the article over while a note is being read (a memory warning, a stalled player, a
/// background seam). The client starts the iOS voice at the source offset of the place it reports, which while a note
/// reads is the note's own offset, the citing sentence's end (`SupertonicSpeechPlaybackClient.currentCharOffset`), and
/// the iOS voice reads the plain text, with the markers spoken and the notes in their chapter at the end.
///
/// What the listener hears then is pinned here from the real planner and the real normalizer, not from a fake: the iOS
/// voice goes on with the sentence after the citing one (it does not replay the citing sentence), and the note it
/// cannot read in place is still in what it reads, in the notes chapter at the end. The iOS voice has no aside chunks
/// (`hasFootnoteAsides` is false under it), so this is the "Read at the end" behaviour of the Design, Flow 7.
final class FootnoteSystemVoiceHandOverTests: XCTestCase {
    private typealias Planner = NarrationChunkPlanner

    /// What the iOS voice reads, from where the client would start it for a hand-over while `noteChunk` of the plan is
    /// the chunk playing: the plain projection of the same text, from the source offset the plan's projection gives.
    private func iosVoiceRemainder(article: String, noteChunk index: Int) throws -> String {
        let plan = Planner.articlePlan(article, asides: true)
        let silenced = try XCTUnwrap(Planner.silencedSpeech(source: article, endingWith: article))
        let note = try XCTUnwrap(plan.chunks.indices.contains(index) ? plan.chunks[index] : nil)
        guard case .aside = note.footnote else { throw XCTSkip("chunk \(index) is not an aside") }
        let source = silenced.sourceOffset(atSpokenCharacterOffset: note.startOffset)
        let plain = SpeechTextNormalizer.normalizeWithSourceOffsets(article)
        return String(plain.text.dropFirst(plain.spokenCharacterOffset(atOrAfterSourceOffset: source)))
    }

    private func asideIndices(_ article: String) -> [Int] {
        Planner.articlePlan(article, asides: true).chunks.enumerated().compactMap {
            if case .aside = $0.element.footnote { $0.offset } else { nil }
        }
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
        Row(name: "a note in the last sentence",
            article: "Tides turn twice a day. They rest between turns.[^1]\n\n[^1]: A closing note.",
            continuesWith: ["footnote 1"],
            stillRead: ["A closing note"]),
        Row(name: "a note followed by a new paragraph",
            article: "Tides turn twice a day.[^1]\n\nThey rest between turns.\n\n[^1]: A note.",
            continuesWith: ["They rest between turns."],
            stillRead: ["A note"]),
    ]

    func testAHandOverDuringANoteGoesOnAfterTheCitingSentenceAndTheNoteStaysInWhatItReads() throws {
        for row in rows {
            let asides = asideIndices(row.article)
            XCTAssertEqual(asides.count, row.continuesWith.count, "\(row.name): one aside per note")
            for (n, index) in asides.enumerated() where n < row.continuesWith.count {
                let remainder = try iosVoiceRemainder(article: row.article, noteChunk: index)
                XCTAssertTrue(
                    remainder.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(row.continuesWith[n]),
                    "\(row.name), note \(n + 1): the iOS voice goes on with \(row.continuesWith[n]), not \(remainder.prefix(40))")
                XCTAssertFalse(
                    remainder.hasPrefix("Tide"), "\(row.name), note \(n + 1): the citing sentence is not replayed")
                XCTAssertTrue(
                    remainder.contains(row.stillRead[n]),
                    "\(row.name), note \(n + 1): the note is still read, in the notes chapter at the end")
            }
        }
    }
}
