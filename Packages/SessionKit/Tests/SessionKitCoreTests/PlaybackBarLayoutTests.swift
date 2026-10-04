import Foundation
import XCTest
@testable import SessionKit

/// The playback bar shows chapters as segments and Margins as diamonds, stacked when too close to tell apart (#428).
final class PlaybackBarLayoutTests: XCTestCase {
    private typealias Layout = PlaybackBarLayout
    private typealias Mark = PlaybackBarLayout.Mark

    // MARK: Chapter segments

    func testNoChaptersIsOneUndividedSegment() {
        let track = Layout.track(chapterStarts: [], length: 3_600, position: 900)
        XCTAssertEqual(track.segments, [.init(start: 0, end: 1, isCurrent: false)])
        XCTAssertEqual(track.boundary, .none, "nothing to divide, and no thicker 'current' bar to grow the row")
    }

    func testAChapterAtTheStartAloneDoesNotDivideTheTrack() {
        XCTAssertEqual(Layout.track(chapterStarts: [0], length: 3_600, position: 10).boundary, .none)
    }

    func testChaptersSplitTheTrackWithGapsAndMarkTheCurrentOne() {
        let track = Layout.track(chapterStarts: [0, 900, 2_700], length: 3_600, position: 1_000)
        XCTAssertEqual(track.boundary, .gaps)
        XCTAssertEqual(track.segments, [
            .init(start: 0, end: 0.25, isCurrent: false),
            .init(start: 0.25, end: 0.75, isCurrent: true),
            .init(start: 0.75, end: 1, isCurrent: false),
        ])
    }

    func testTheStretchBeforeTheFirstChapterIsItsOwnSegment() {
        let track = Layout.track(chapterStarts: [1_800], length: 3_600, position: 60)
        XCTAssertEqual(track.segments, [
            .init(start: 0, end: 0.5, isCurrent: true),
            .init(start: 0.5, end: 1, isCurrent: false),
        ])
    }

    func testUnsortedRepeatedAndOutOfRangeStartsAreCleanedUp() {
        let track = Layout.track(chapterStarts: [2_700, 900, 900, -5, 3_600, 9_000, .nan], length: 3_600, position: nil)
        XCTAssertEqual(track.segments.map(\.start), [0, 0.25, 0.75])
        XCTAssertEqual(track.segments.last?.end, 1)
        XCTAssertFalse(track.segments.contains(where: \.isCurrent), "no position, no current chapter")
    }

    func testFortyChaptersShowTicksInsteadOfGapsAndCoverTheWholeTrack() {
        let starts = (0..<40).map { Double($0) * 90 }
        let track = Layout.track(chapterStarts: starts, length: 3_600, position: 3_599)
        XCTAssertEqual(track.segments.count, 40)
        XCTAssertEqual(track.boundary, .ticks)
        XCTAssertEqual(track.segments.filter(\.isCurrent).count, 1)
        XCTAssertTrue(track.segments.last!.isCurrent)
        for (segment, next) in zip(track.segments, track.segments.dropFirst()) {
            XCTAssertEqual(segment.end, next.start, "segments meet with no hole in the track")
        }
    }

    func testTwentyChaptersStillShowGaps() {
        let starts = (0..<20).map { Double($0) * 180 }
        XCTAssertEqual(Layout.track(chapterStarts: starts, length: 3_600, position: 0).boundary, .gaps)
    }

    func testAnEmptyBarHasNoSegments() {
        XCTAssertTrue(Layout.track(chapterStarts: [10], length: 0, position: 0).segments.isEmpty)
    }

    // MARK: Margin stacks

    func testTwoMarginsOneSecondApartShareOneStack() {
        let stacks = Layout.stacks(marks: [
            Mark(id: "b", position: 1_201, kind: .shared),
            Mark(id: "a", position: 1_200, kind: .own),
        ], length: 3_600, width: 300)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0].members.map(\.id), ["a", "b"], "the earlier Margin is the front diamond")
        XCTAssertEqual(stacks[0].x, 100, accuracy: 0.001)
        XCTAssertEqual(stacks[0].layers, [.own, .shared])
        XCTAssertEqual(stacks[0].ghostLayers, 0)
        XCTAssertNil(stacks[0].countLabel)
    }

    func testMarginsFurtherApartThanSixPointsStaySeparate() {
        // 300 pt for an hour: 1 pt is 12 s, so 84 s apart is 7 pt.
        let stacks = Layout.stacks(marks: [
            Mark(id: "a", position: 1_200, kind: .own),
            Mark(id: "b", position: 1_284, kind: .own),
        ], length: 3_600, width: 300)
        XCTAssertEqual(stacks.map { $0.members.map(\.id) }, [["a"], ["b"]])
    }

    func testAStackDoesNotCreepAlongTheBarThroughAChainOfNearbyMarks() {
        // Each mark is 4 pt from the last; without an anchor these would chain into one wide stack.
        let marks = (0..<4).map { Mark(id: "m\($0)", position: Double($0) * 48, kind: .own) }
        let stacks = Layout.stacks(marks: marks, length: 3_600, width: 300)
        XCTAssertEqual(stacks.map { $0.members.map(\.id) }, [["m0", "m1"], ["m2", "m3"]])
    }

    func testFiveMarginsInOneSpotShowFiveRealLayers() {
        let marks = (0..<5).map { Mark(id: "m\($0)", position: 600, kind: $0 == 0 ? .shared : .own) }
        let stack = Layout.stacks(marks: marks, length: 3_600, width: 300)[0]
        XCTAssertEqual(stack.layers, [.shared, .own, .own, .own, .own])
        XCTAssertEqual(stack.ghostLayers, 0)
        XCTAssertNil(stack.countLabel)
    }

    func testTwelveMarginsInOneSpotShowThreeGhostLayersAndTheCount() {
        let marks = (0..<12).map { Mark(id: String(format: "m%02d", $0), position: 600, kind: $0 < 4 ? .shared : .own) }
        let stacks = Layout.stacks(marks: marks, length: 3_600, width: 300)
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(stacks[0].members.count, 12)
        XCTAssertEqual(stacks[0].layers, [.shared], "only the front diamond is drawn for real")
        XCTAssertEqual(stacks[0].ghostLayers, 3)
        XCTAssertEqual(stacks[0].countLabel, "12")
        XCTAssertEqual(stacks[0].accessibilityLabel(at: "10:00"), "12 Margins at 10:00, 4 shared")
    }

    func testMarksPastTheEndsSitAtTheEndsAndUnplaceableOnesAreLeftOut() {
        let stacks = Layout.stacks(marks: [
            Mark(id: "late", position: 4_000, kind: .own),
            Mark(id: "early", position: -3, kind: .own),
            Mark(id: "nowhere", position: .nan, kind: .own),
        ], length: 3_600, width: 300)
        XCTAssertEqual(stacks.map(\.x), [0, 300])
        XCTAssertEqual(stacks.map { $0.members.map(\.id) }, [["early"], ["late"]])
    }

    func testVoiceOverNamesWhoseMarginsAreThere() {
        let own = Mark(id: "a", position: 10, kind: .own)
        let shared = Mark(id: "b", position: 10, kind: .shared)
        XCTAssertEqual(Layout.Stack(x: 0, members: [own]).accessibilityLabel(at: "9:22"), "Your Margin at 9:22")
        XCTAssertEqual(Layout.Stack(x: 0, members: [shared]).accessibilityLabel(at: "40%"), "Shared Margin at 40%")
        XCTAssertEqual(Layout.Stack(x: 0, members: [own, own, own]).accessibilityLabel(at: "9:22"), "3 Margins at 9:22")
        XCTAssertEqual(Layout.Stack(x: 0, members: [shared, shared]).accessibilityLabel(at: "9:22"), "2 Margins at 9:22, all shared")
    }

    // MARK: Where a Margin sits

    func testAnOwnPodcastMarginSitsAtItsRecordedTimeElseItsRoughPercent() {
        XCTAssertEqual(Mark.media(margin(mediaTimeMs: 562_000, roughPercent: 3), durationSeconds: 3_600),
                       Mark(id: "own", position: 562, kind: .own))
        XCTAssertEqual(Mark.media(margin(mediaTimeMs: nil, roughPercent: 25), durationSeconds: 3_600)?.position, 900)
    }

    func testAMarginOnASummaryTurnIsNotOnTheSourceBar() {
        XCTAssertNil(Mark.media(margin(target: .summaryTurn, mediaTimeMs: 1_000, roughPercent: 1), durationSeconds: 3_600))
        XCTAssertNil(Mark.text(margin(target: .assistantTurn, startChar: 40)))
    }

    func testAnOwnTextMarginSitsAtItsCharacter() {
        XCTAssertEqual(Mark.text(margin(startChar: 4_200)), Mark(id: "own", position: 4_200, kind: .own))
    }

    func testASharedPodcastMarginSitsWhereTheTimelineListsIt() {
        let matched = shared(.init(evidenceClass: .acousticVerified, localMediaTimeMs: 332_900), senderMs: 302_926, roughPercent: 9)
        XCTAssertEqual(Mark.media(matched, durationSeconds: 3_600), Mark(id: "shared", position: 332.9, kind: .shared))
        let ambiguous = shared(.init(evidenceClass: .ambiguous, localMediaTimeMs: 900_000, isAmbiguous: true), senderMs: 302_926)
        XCTAssertEqual(Mark.media(ambiguous, durationSeconds: 3_600)?.position, 900, "the Timeline uses the strongest candidate")
        // The sender's copy ran longer: 50% of this 60-minute copy is 30:00, not the sender's 35:00.
        let unmatched = shared(.init(evidenceClass: .unresolved), senderMs: 2_100_000, roughPercent: 50)
        XCTAssertEqual(Mark.media(unmatched, durationSeconds: 3_600)?.position, 1_800)
        XCTAssertNil(Mark.media(shared(.init(evidenceClass: .unresolved), senderMs: 2_100_000), durationSeconds: 3_600),
                     "the Timeline only sorts this one last; a diamond at the end would be a made-up place")
    }

    func testASharedTextMarginSitsAtTheSendersRoughPercentAsInTheTimeline() {
        let matched = shared(.init(evidenceClass: .articleTextVerified, localStartChar: 1_234), roughPercent: 90)
        XCTAssertEqual(Mark.text(matched, textLength: 10_000)?.position, 9_000)
        XCTAssertNil(Mark.text(shared(.init(evidenceClass: .unresolved)), textLength: 10_000))
    }

    // MARK: Fixtures

    private func margin(
        target: InterjectionTargetType = .item, mediaTimeMs: Int? = nil, roughPercent: Int = 0, startChar: Int = 0
    ) -> Interjection {
        Interjection(
            id: "own", itemId: "item", sessionId: "session", targetType: target, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: roughPercent,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil,
            cleanedTranscript: nil, displayText: "A Margin", status: "active"
        )
    }

    private func shared(
        _ resolution: ImportedAnchorResolution, senderMs: Int? = nil, roughPercent: Int? = nil
    ) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: "shared", layerId: "layer-1", packageScopedId: "pkg::ij-001",
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(
                anchorType: senderMs == nil ? .text : .media, mediaTimeMs: senderMs, roughPercent: roughPercent
            ),
            approvedTranscript: "Nice job, Joe.", resolution: resolution
        )
    }
}
