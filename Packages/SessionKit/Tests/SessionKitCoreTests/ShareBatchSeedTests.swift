import XCTest
import SessionKit

/// #4647 PR 0: the Test Desk seed has the shape the cleanup needs: fillers to remove, two long gaps, and a recording
/// length that matches its words.
final class ShareBatchSeedTests: XCTestCase {
    func testEachMarginHasFillersTwoLongGapsAndAMatchingLength() {
        for margin in 1...ShareBatchSeed.marginCount {
            let transcript = ShareBatchSeed.transcript(margin: margin)
            let words = transcript.segments.map(\.text)
            XCTAssertEqual(words.count, ShareBatchSeed.lineCount * 10)
            XCTAssertTrue(words.contains("um") && words.contains("uh"), "margin \(margin) has fillers")
            let gaps = zip(transcript.segments, transcript.segments.dropFirst()).filter { $1.startMs - $0.endMs > 0 }
            XCTAssertEqual(gaps.map { $1.startMs - $0.endMs }, [ShareBatchSeed.gapMs, ShareBatchSeed.gapMs])
            XCTAssertEqual(ShareBatchSeed.durationMs(margin: margin), words.count * ShareBatchSeed.wordMs + 2 * ShareBatchSeed.gapMs)
            XCTAssertEqual(transcript.text, ShareBatchSeed.text(margin: margin))
            XCTAssertEqual(Set(transcript.segments.map(\.id)).count, words.count, "segment ids are unique")
        }
    }

    func testTheGapsAreSilentAndTheWordsSound() throws {
        let transcript = ShareBatchSeed.transcript(margin: 1)
        let gapIndex = try XCTUnwrap(ShareBatchSeed.gapsAfter(wordCount: transcript.segments.count).min())
        let gapStart = transcript.segments[gapIndex].endMs
        XCTAssertFalse(ShareBatchSeed.isVoiced(atMs: gapStart + 600, margin: 1))
        XCTAssertTrue(ShareBatchSeed.isVoiced(atMs: 150, margin: 1))
        XCTAssertEqual(ShareBatchSeed.starredMargins, [2, 4])
    }
}
