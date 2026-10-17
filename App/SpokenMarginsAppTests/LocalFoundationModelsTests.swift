import XCTest
import SessionKit
@testable import SpokenMarginsApp

final class LocalFoundationModelsTests: XCTestCase {
    func testPlannerUsesSemanticShiftAfterMinimumChunkSize() throws {
        let alpha = String(repeating: "Alpha context evidence structure. ", count: 45)
        let beta = String(repeating: "Beta implementation navigation audio. ", count: 45)
        let source = "\(alpha) \(alpha) \(beta) \(beta)"
        let planner = LocalListeningMapPlanner { text in
            let lowered = text.lowercased()
            let alphaCount = Double(lowered.components(separatedBy: "alpha").count - 1)
            let betaCount = Double(lowered.components(separatedBy: "beta").count - 1)
            return [alphaCount, betaCount]
        }

        let draft = try planner.makeDraft(text: source, timeline: nil)

        XCTAssertGreaterThanOrEqual(draft.chapters.count, 2)
        XCTAssertEqual(draft.chapters.first?.startChar, 0)
        XCTAssertEqual(draft.chapters.last?.endChar, source.trimmingCharacters(in: .whitespacesAndNewlines).count)
        XCTAssertTrue(zip(draft.chapters, draft.chapters.dropFirst()).allSatisfy { lhs, rhs in
            lhs.endChar <= rhs.startChar
        })
        // #1044 APO-12: the break lands where the topic changes, not wherever the size limit falls.
        let firstBeta = try XCTUnwrap(source.range(of: "Beta"))
        XCTAssertEqual(draft.chapters.count, 2, "one chapter per topic: \(draft.chapters.map(\.startChar))")
        XCTAssertEqual(draft.chapters.dropFirst().first?.startChar, source.distance(from: source.startIndex, to: firstBeta.lowerBound))
        XCTAssertEqual(draft.chapters.dropFirst().first?.text.hasPrefix("Beta"), true)
    }

    func testPlannerKeepsOneTopicInOneChapterBelowTheHardLimit() throws {
        // About 5,100 characters of one topic: past the 2,500-character minimum, short of the 6,000 hard limit.
        let source = String(repeating: "Alpha context evidence structure. ", count: 150)
        let planner = LocalListeningMapPlanner { text in
            let lowered = text.lowercased()
            return [Double(lowered.components(separatedBy: "alpha").count - 1),
                    Double(lowered.components(separatedBy: "beta").count - 1)]
        }

        let draft = try planner.makeDraft(text: source, timeline: nil)

        XCTAssertEqual(draft.chapters.count, 1, "split without a topic change: \(draft.chapters.map(\.startChar))")
    }

    func testPlannerCarriesExactMediaNavigationAnchorsIntoDraft() throws {
        let firstText = String(repeating: "Opening ideas and context. ", count: 55)
        let secondText = String(repeating: "A distant topic and practical consequences. ", count: 55)
        let source = "\(firstText) \(secondText)"
        let timeline = TranscriptTimeline(
            segments: [
                MediaTimelineSegment(id: "segment-opening", startMs: 0, endMs: 240_000, startChar: 0, endChar: firstText.count, text: firstText),
                MediaTimelineSegment(id: "segment-pivot", startMs: 240_000, endMs: 480_000, startChar: firstText.count + 1, endChar: source.count, text: secondText)
            ],
            chapters: [],
            durationMs: 480_000
        )
        let planner = LocalListeningMapPlanner { text in
            text.contains("Opening") ? [1, 0] : [0, 1]
        }

        let draft = try planner.makeDraft(text: source, timeline: timeline)

        XCTAssertEqual(draft.chapters.first?.startMs, 0)
        XCTAssertEqual(draft.chapters.first?.transcriptSegmentId, "segment-opening")
        XCTAssertEqual(draft.chapters.last?.startMs, 240_000)
        XCTAssertEqual(draft.chapters.last?.transcriptSegmentId, "segment-pivot")
    }
}
