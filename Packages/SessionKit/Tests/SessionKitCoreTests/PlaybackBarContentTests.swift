import Foundation
import XCTest
@testable import SessionKit

/// What the playback bar is given for a podcast or a text source (#428).
final class PlaybackBarContentTests: XCTestCase {
    func testAPodcastBarIsMeasuredInSecondsWithItsChaptersAndBothKindsOfMargin() throws {
        let content = try XCTUnwrap(PlaybackBarContent.media(
            durationMs: 3_600_000,
            chapterStartsMs: [0, 900_000, 2_700_000],
            own: [margin(id: "mine", mediaTimeMs: 562_000)],
            shared: [shared(id: "theirs", .init(evidenceClass: .acousticVerified, localMediaTimeMs: 332_900))]
        ))
        XCTAssertEqual(content.length, 3_600)
        XCTAssertEqual(content.chapterStarts, [0, 900, 2_700])
        XCTAssertEqual(content.marks, [
            .init(id: "mine", position: 562, kind: .own),
            .init(id: "theirs", position: 332.9, kind: .shared),
        ])
    }

    func testATextBarIsMeasuredInCharactersAndLeavesOutMarginsWithNoHonestPlace() throws {
        let content = try XCTUnwrap(PlaybackBarContent.text(
            length: 10_000,
            chapterStartChars: [0, 4_000],
            own: [margin(id: "mine", startChar: 4_200), margin(id: "spoken-on-a-summary", target: .summaryTurn)],
            shared: [
                shared(id: "theirs", .init(evidenceClass: .articleTextVerified), roughPercent: 90),
                shared(id: "unplaced", .init(evidenceClass: .unresolved)),
            ]
        ))
        XCTAssertEqual(content.length, 10_000)
        XCTAssertEqual(content.chapterStarts, [0, 4_000])
        XCTAssertEqual(content.marks.map(\.id), ["mine", "theirs"])
        XCTAssertEqual(content.marks.map(\.position), [4_200, 9_000])
    }

    func testASourceWithoutALengthHasNothingToDraw() {
        XCTAssertNil(PlaybackBarContent.media(durationMs: 0, chapterStartsMs: [0, 10], own: [], shared: []))
        XCTAssertNil(PlaybackBarContent.text(length: 0, chapterStartChars: [0, 10], own: [], shared: []))
    }

    func testTheContentFeedsTheLayoutDirectly() throws {
        let content = try XCTUnwrap(PlaybackBarContent.media(
            durationMs: 3_600_000,
            chapterStartsMs: [0, 900_000],
            own: (0..<12).map { margin(id: "m\($0)", mediaTimeMs: 1_800_000 + $0 * 100) },
            shared: []
        ))
        let track = PlaybackBarLayout.track(chapterStarts: content.chapterStarts, length: content.length, position: 1_000)
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertTrue(track.segments[1].isCurrent)
        let stacks = PlaybackBarLayout.stacks(marks: content.marks, length: content.length, width: 300)
        XCTAssertEqual(stacks.count, 1, "twelve Margins within two seconds of each other share one spot")
        XCTAssertEqual(stacks[0].countLabel, "12")
    }

    // MARK: Fixtures

    private func margin(
        id: String, target: InterjectionTargetType = .item, mediaTimeMs: Int? = nil, startChar: Int = 0
    ) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: target, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 0,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
            cleanedTranscript: nil, displayText: "A Margin", status: "active"
        )
    }

    private func shared(
        id: String, _ resolution: ImportedAnchorResolution, roughPercent: Int? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer-1", packageScopedId: "pkg::\(id)",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text, mediaTimeMs: nil, roughPercent: roughPercent),
            approvedTranscript: "Nice job, Joe.", resolution: resolution
        )
    }
}
