import Foundation
import XCTest
@testable import SessionKit

/// #3777: an aside starts where the next body chunk starts, so a chunk's start offset no longer names it. The player
/// keys its per-chunk state (rendered audio, renders in flight, durations) by `ChunkKey` instead.
final class NarrationChunkKeyTests: XCTestCase {
    private typealias Planner = NarrationChunkPlanner

    private let tides = """
    The tide turns twice a day.[^1] It rests between turns.[^2] Boats wait for it.[^1] Then they leave.

    [^1]: Smith, Tides, 2020.
    [^2]: Lee, Boats, 2021.
    """

    private func spokenChunks(_ text: String, asides: Bool) -> [Planner.SpokenChunk] {
        let silenced = asides ? Planner.silencedCitationRanges(inArticle: text) : []
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(text, silencingSourceRanges: silenced)
        return Planner.spokenPlan(spokenText: projection.text, articleText: text, articleSpokenStart: 0, asides: asides).chunks
    }

    func testEveryChunkOfAPlanWithAsidesHasItsOwnKey() {
        let chunks = spokenChunks(tides, asides: true)
        XCTAssertTrue(chunks.contains(where: \.isAside), "the fixture must plan an aside")
        let keys = Planner.chunkKeys(for: chunks)
        XCTAssertEqual(keys.count, chunks.count)
        XCTAssertEqual(Set(keys).count, keys.count, "two chunks share a key: \(keys)")
        // The start offsets alone are not unique: that is what the key exists for.
        XCTAssertLessThan(Set(chunks.map(\.startOffset)).count, chunks.count)
    }

    func testAnAsideComesBeforeTheBodyChunkThatStartsWhereItDoes() {
        let chunks = spokenChunks(tides, asides: true)
        let keys = Planner.chunkKeys(for: chunks)
        XCTAssertEqual(keys, keys.sorted(), "keys compare in plan order")
        for (index, chunk) in chunks.enumerated() where chunk.isAside {
            XCTAssertEqual(chunk.sourceLength, 0)
            XCTAssertEqual(keys[index].startOffset, chunk.startOffset)
            let next = chunks[index + 1]
            XCTAssertEqual(next.startOffset, chunk.startOffset)
            XCTAssertGreaterThan(keys[index + 1], keys[index])
        }
    }

    func testAPlanWithNoAsideHasItsStartOffsetsAsKeys() {
        for asides in [false, true] {
            for text in ["Plain prose. Another sentence of it. And a third one to be sure.", tides] where !asides || text != tides {
                let chunks = spokenChunks(text, asides: asides)
                XCTAssertFalse(chunks.contains(where: \.isAside))
                XCTAssertEqual(Planner.chunkKeys(for: chunks), chunks.map { .init(startOffset: $0.startOffset, ordinal: 0) })
            }
        }
        // A footnoted article read the way it is today: the marker spoken, no aside, no shared offset.
        let today = spokenChunks(tides, asides: false)
        XCTAssertEqual(Planner.chunkKeys(for: today).map(\.ordinal), Array(repeating: 0, count: today.count))
    }

    func testAKeyIsTheSameEveryTimeAndForTheHeadOfASplitChunk() {
        let chunks = spokenChunks(tides, asides: true)
        XCTAssertEqual(Planner.chunkKeys(for: chunks), Planner.chunkKeys(for: chunks))
        let text = (1...4).map { "Sentence number \($0) is long enough to cost something when it is spoken." }.joined(separator: " ")
        let body = SpeechTextNormalizer.normalize(text)
        let plain = Planner.spokenPlan(spokenText: body, articleText: text, articleSpokenStart: 0).chunks
        let split = Planner.splittingFirstChunk(of: plain, spokenText: body, playheadOffset: 0, headBudget: 20)
        XCTAssertGreaterThan(split.count, plain.count)
        XCTAssertEqual(Planner.chunkKeys(for: split).first, Planner.chunkKeys(for: plain).first)
    }

    func testAnAsideNeverHoldsAPlayheadForAFastStartSplit() {
        let silenced = Planner.silencedCitationRanges(inArticle: tides)
        let spokenText = SpeechTextNormalizer.normalizeWithSourceOffsets(tides, silencingSourceRanges: silenced).text
        let chunks = Planner.spokenPlan(spokenText: spokenText, articleText: tides, articleSpokenStart: 0, asides: true).chunks
        guard let aside = chunks.first(where: \.isAside) else { return XCTFail("no aside planned") }
        let split = Planner.splittingFirstChunk(of: chunks, spokenText: spokenText, playheadOffset: aside.startOffset, headBudget: 8)
        XCTAssertTrue(split.contains(aside), "the aside is kept whole, not split")
        XCTAssertEqual(split.filter(\.isAside).count, chunks.filter(\.isAside).count)
        let keys = Planner.chunkKeys(for: split)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
