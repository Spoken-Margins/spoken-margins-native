import Foundation
import XCTest
@testable import SessionKit

/// One owner for every lead-in (#807): Play this moment, a friend's cut and Listen Back.
final class ListeningMomentTests: XCTestCase {
    private let margin = ListeningMoment.Margin(id: "ij-003", position: 120_000)

    func testEachUseHasItsOwnLeadInAndCarryOn() {
        let play = ListeningMoment(use: .playThisMoment, margin: margin, source: .media())
        XCTAssertEqual(play.leadIn, .onPhone(.init(start: 90_000, end: 120_000)))
        XCTAssertEqual(play.carryOn, .sourceContinues)

        let cut = ListeningMoment(use: .friendsCut, margin: margin, source: .media())
        XCTAssertEqual(cut.leadIn, .onPhone(.init(start: 100_000, end: 120_000)))
        XCTAssertEqual(cut.carryOn, .play(.init(start: 120_000, end: 123_000), fadesOut: true))

        let back = ListeningMoment(use: .listenBack, margin: margin, source: .media())
        XCTAssertEqual(back.leadIn, .onPhone(.init(start: 112_000, end: 120_000)))
        XCTAssertEqual(back.carryOn, .none)

        for moment in [play, cut, back] { XCTAssertNil(moment.leadInClamp) }
    }

    func testPlayThisMomentKeepsTheSequencesLeadIn() {
        XCTAssertEqual(MarginMomentSequence.defaultLeadInMs, 30_000)
        XCTAssertEqual(ListeningMoment.rule(for: .playThisMoment).leadInMs, MarginMomentSequence.defaultLeadInMs)
    }

    func testATrimmedLeadInOverridesTheUsesLength() {
        let trimmed = ListeningMoment(use: .friendsCut, margin: margin, source: .media(), leadInMs: 5_000)
        XCTAssertEqual(trimmed.sourceStartPosition, 115_000)
    }

    func testAMarginNearTheStartClampsToZeroAndSaysSo() {
        let early = ListeningMoment.Margin(id: "ij-001", position: 5_000)
        for use in ListeningMoment.Use.allCases {
            let moment = ListeningMoment(use: use, margin: early, source: .media())
            XCTAssertEqual(moment.leadIn.span, .init(start: 0, end: 5_000), "\(use)")
            XCTAssertEqual(moment.leadInClamp, .sourceStart, "\(use)")
        }
        let exact = ListeningMoment(use: .listenBack, margin: .init(id: "ij-002", position: 8_000), source: .media())
        XCTAssertNil(exact.leadInClamp, "a lead-in that just fits isn't clamped")
    }

    func testTwoMarginsSixSecondsApartInAListenBackPlanDontOverlap() {
        let first = ListeningMoment.Margin(id: "ij-a", position: 60_000)
        let second = ListeningMoment.Margin(id: "ij-b", position: 66_000)
        let plan = ListeningMoment.plan(use: .listenBack, margins: [second, first], source: .media())
        XCTAssertEqual(plan.map(\.margin), [first, second], "in playback order")
        XCTAssertEqual(plan[0].leadIn.span, .init(start: 52_000, end: 60_000))
        XCTAssertNil(plan[0].leadInClamp)
        XCTAssertEqual(plan[1].leadIn.span, .init(start: 60_000, end: 66_000), "stops at the previous Margin")
        XCTAssertEqual(plan[1].leadInClamp, .previousMargin("ij-a"))
    }

    func testAPreviousMarginOutsideTheLeadInChangesNothing() {
        let far = ListeningMoment.Margin(id: "ij-a", position: 10_000)
        let moment = ListeningMoment(use: .listenBack, margin: margin, source: .media(), previousMargin: far)
        XCTAssertEqual(moment.leadIn.span, .init(start: 112_000, end: 120_000))
        XCTAssertNil(moment.leadInClamp)
    }

    func testTextLeadsInFromTheStartOfTheSentenceBefore() {
        // Sentences start at 0, 40, 95 and 150; the Margin sits in the third sentence.
        let source = ListeningMoment.Source.text(sentenceStarts: [0, 40, 95, 150])
        let inThird = ListeningMoment.Margin(id: "ij-t", position: 120)
        for use in ListeningMoment.Use.allCases {
            let moment = ListeningMoment(use: use, margin: inThird, source: source)
            XCTAssertEqual(moment.leadIn, .onPhone(.init(start: 40, end: 120)), "\(use): seconds don't apply to text")
            XCTAssertNil(moment.leadInClamp)
        }
        let atSentenceStart = ListeningMoment(use: .listenBack, margin: .init(id: "ij-s", position: 95), source: source)
        XCTAssertEqual(atSentenceStart.leadIn.span, .init(start: 40, end: 95))
        let repeated = ListeningMoment.Source.text(sentenceStarts: [95, 0, 40, 95])
        XCTAssertEqual(ListeningMoment(use: .listenBack, margin: inThird, source: repeated).leadIn.span?.start, 40)
    }

    func testTextMarginInTheFirstSentenceLeadsInFromTheStart() {
        let source = ListeningMoment.Source.text(sentenceStarts: [0, 40, 95])
        let moment = ListeningMoment(use: .friendsCut, margin: .init(id: "ij-f", position: 25), source: source)
        XCTAssertEqual(moment.leadIn.span, .init(start: 0, end: 25))
        XCTAssertEqual(moment.leadInClamp, .sourceStart)
        XCTAssertEqual(moment.carryOn, .none, "a carry-on in seconds has no meaning for text")
    }

    func testTextLeadInStopsAtThePreviousMargin() {
        let source = ListeningMoment.Source.text(sentenceStarts: [0, 40, 95])
        let plan = ListeningMoment.plan(
            use: .listenBack,
            margins: [.init(id: "ij-1", position: 60), .init(id: "ij-2", position: 110)],
            source: source
        )
        XCTAssertEqual(plan[1].leadIn.span, .init(start: 60, end: 110))
        XCTAssertEqual(plan[1].leadInClamp, .previousMargin("ij-1"))
    }

    func testFallbacksWhenTheSourceIsntOnThePhone() {
        let streamable = ListeningMoment.Source.media(
            isOnPhone: false, canStream: true, hasContextText: true, hasPacketQuote: true
        )
        XCTAssertEqual(
            ListeningMoment(use: .playThisMoment, margin: margin, source: streamable).leadIn,
            .stream(.init(start: 90_000, end: 120_000))
        )
        let cutOnStream = ListeningMoment(use: .friendsCut, margin: margin, source: streamable)
        XCTAssertEqual(cutOnStream.leadIn, .stream(.init(start: 100_000, end: 120_000)))
        XCTAssertEqual(cutOnStream.carryOn, .play(.init(start: 120_000, end: 123_000), fadesOut: true))
        XCTAssertEqual(
            ListeningMoment(use: .listenBack, margin: margin, source: streamable).leadIn, .readContextText,
            "Listen Back never streams to make a recap"
        )

        let articleNotFetched = ListeningMoment.Source.text(sentenceStarts: [0, 40], isOnPhone: false, hasPacketQuote: true)
        let quoted = ListeningMoment(use: .friendsCut, margin: .init(id: "ij-t", position: 60), source: articleNotFetched)
        XCTAssertEqual(quoted.leadIn, .readPacketQuote)
        XCTAssertEqual(quoted.carryOn, .none)
        XCTAssertNil(quoted.leadInClamp)
        XCTAssertEqual(quoted.sourceStartPosition, 60)
    }

    func testNothingToLeadInWithSkipsTheLeadIn() {
        let nothing = ListeningMoment.Source.media(isOnPhone: false)
        for use in ListeningMoment.Use.allCases {
            let moment = ListeningMoment(use: use, margin: margin, source: nothing)
            XCTAssertEqual(moment.leadIn, .skip, "\(use)")
            XCTAssertEqual(moment.carryOn, .none, "\(use)")
        }
        let textCantStream = ListeningMoment.Source(timeline: .text(sentenceStarts: [0]), isOnPhone: false, canStream: true)
        XCTAssertEqual(ListeningMoment(use: .playThisMoment, margin: margin, source: textCantStream).leadIn, .skip)
    }

    func testCarryOnPastTheEndOfTheSourceStopsAtTheEnd() {
        let nearEnd = ListeningMoment.Margin(id: "ij-z", position: 1_799_000)
        let moment = ListeningMoment(use: .friendsCut, margin: nearEnd, source: .media(durationMs: 1_800_000))
        XCTAssertEqual(moment.carryOn, .play(.init(start: 1_799_000, end: 1_800_000), fadesOut: true))
        let atEnd = ListeningMoment(
            use: .friendsCut, margin: .init(id: "ij-end", position: 1_800_000), source: .media(durationMs: 1_800_000)
        )
        XCTAssertEqual(atEnd.carryOn, .none)
    }
}
