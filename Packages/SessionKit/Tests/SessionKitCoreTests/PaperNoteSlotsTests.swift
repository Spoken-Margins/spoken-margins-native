import Foundation
import XCTest
@testable import SessionKit

/// #4340 PR 4: what the Paper note section on a PDF's item screen shows.
final class PaperNoteSlotsTests: XCTestCase {
    /// Four segments on two pages, so the first and third have a known page (1 and 2).
    private let text = "Page one first. Page one second.\nPage two first. Page two last."
    private lazy var document = StructuredDocument(
        extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
        text: text,
        segments: [
            .init(id: "s0", role: .body, range: .init(start: 0, length: 15), pageIndex: 0),
            .init(id: "s1", role: .body, range: .init(start: 16, length: 16), pageIndex: 0),
            .init(id: "s2", role: .body, range: .init(start: 33, length: 15), pageIndex: 1),
            .init(id: "s3", role: .body, range: .init(start: 49, length: 14), pageIndex: 1),
        ],
        markers: []
    )
    private let onPage1 = 2
    private let onPage2 = 35

    private func margin(
        _ id: String, _ role: PaperNoteRole?, at start: Int = 2, item: String = "p1", session: String = "s", created: Double = 1,
        status: String = "active", target: InterjectionTargetType = .item
    ) -> Interjection {
        Interjection(
            id: id, itemId: item, sessionId: session, targetType: target, targetId: item,
            createdAt: Date(timeIntervalSince1970: created), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: start, endChar: start + 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "words \(id)", status: status, captureKind: .written, paperRole: role
        )
    }

    private func slots(_ margins: [Interjection], withDocument: Bool = true) -> PaperNoteSlots {
        PaperNoteSlots(paper: .init(itemId: "p1", title: "A Paper", document: withDocument ? document : nil, margins: margins))
    }

    /// Each row as "role:marginId" or "role:empty".
    private func shape(_ slots: PaperNoteSlots) -> [String] {
        slots.rows.map { row in
            switch row {
            case .empty(let role, _): "\(role.rawValue):empty"
            case .filled(let answer): "\(row.role.rawValue):\(answer.margin.id)"
            }
        }
    }

    // MARK: Slots

    func testAPaperWithNoMarginsShowsFiveEmptySlotsAndNoChoices() {
        let slots = slots([])
        XCTAssertEqual(shape(slots), ["purpose:empty", "keyFinding:empty", "evidence:empty", "evidence:empty", "evidence:empty"])
        XCTAssertTrue(slots.hasNoMargins)
        XCTAssertFalse(slots.offersMoreEvidence)
        XCTAssertEqual(Set(slots.rows.map(\.id)).count, 5, "every row has its own id")
    }

    func testMarginsWithoutARoleAreChoicesButFillNoSlot() {
        let slots = slots([margin("a", nil), margin("b", nil, at: onPage2)])
        XCTAssertEqual(shape(slots), ["purpose:empty", "keyFinding:empty", "evidence:empty", "evidence:empty", "evidence:empty"])
        XCTAssertEqual(slots.choices.map(\.margin.id), ["a", "b"])
        XCTAssertFalse(slots.hasNoMargins)
    }

    func testFilledEvidenceComesBeforeTheEmptyRows() {
        let slots = slots([margin("e1", .evidence, at: onPage2), margin("p", .purpose)])
        XCTAssertEqual(shape(slots), ["purpose:p", "keyFinding:empty", "evidence:e1", "evidence:empty", "evidence:empty"])
    }

    func testARoleAnsweredTwiceShowsBothInPageOrder() {
        let slots = slots([
            margin("later", .purpose, at: onPage2, created: 1),
            margin("earlier", .purpose, at: onPage1, created: 2),
        ])
        XCTAssertEqual(Array(shape(slots).prefix(3)), ["purpose:earlier", "purpose:later", "keyFinding:empty"])
    }

    func testThreeEvidenceOffersMoreAndAFourthAddsARow() {
        let three = slots([margin("e1", .evidence), margin("e2", .evidence, at: onPage2), margin("e3", .evidence, at: onPage2 + 3)])
        XCTAssertEqual(Array(shape(three).suffix(3)), ["evidence:e1", "evidence:e2", "evidence:e3"])
        XCTAssertTrue(three.offersMoreEvidence)

        let four = slots(three.choices.map(\.margin) + [margin("e4", .evidence, at: onPage2 + 6)])
        XCTAssertEqual(Array(shape(four).suffix(4)), ["evidence:e1", "evidence:e2", "evidence:e3", "evidence:e4"])
        XCTAssertTrue(four.offersMoreEvidence)

        let two = slots(Array(three.choices.map(\.margin).prefix(2)))
        XCTAssertFalse(two.offersMoreEvidence)
    }

    func testOnlyThisPapersActiveItemMarginsCount() {
        let slots = slots([
            margin("other-item", .purpose, item: "p2"),
            margin("deleted", .purpose, status: "deleted"),
            margin("summary", .purpose, target: .summaryTurn),
            margin("mine", nil),
        ])
        XCTAssertEqual(shape(slots).first, "purpose:empty")
        XCTAssertEqual(slots.choices.map(\.margin.id), ["mine"])
    }

    func testTheSameMarginIdInTwoSessionsIsTwoAnswers() {
        let slots = slots([margin("m", .evidence, session: "s1"), margin("m", .evidence, at: onPage2, session: "s2")])
        let ids = slots.rows.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "rows keep distinct ids across sessions")
        XCTAssertEqual(slots.choices.count, 2)
    }

    // MARK: Place line

    func testAKnownPageReadsAsAPageAndAnUnknownOneFallsBack() {
        let withPage = slots([margin("a", .purpose, at: onPage2)])
        guard case .filled(let answer) = withPage.rows[0] else { return XCTFail("purpose is filled") }
        XCTAssertEqual(answer.placeLine, "p. 2")

        let noDocument = slots([margin("a", .purpose, at: onPage2)], withDocument: false)
        guard case .filled(let fallback) = noDocument.rows[0] else { return XCTFail("purpose is filled") }
        XCTAssertNil(fallback.page)
        XCTAssertEqual(fallback.placeLine, "At 40%")
    }

    func testChoicesWithAKnownPageComeBeforeOnesWithout() {
        // Character 20 is in s1, whose page is uncertain (the next segment starts on page 2); character 60 is in the last
        // segment, on the last page. The unknown page sorts last though its text comes earlier.
        let slots = slots([margin("late", nil, at: 60), margin("unknown", nil, at: 20), margin("first", nil, at: onPage1)])
        XCTAssertEqual(slots.choices.map(\.page), [1, 2, nil])
        XCTAssertEqual(slots.choices.map(\.margin.id), ["first", "late", "unknown"])
    }

    // MARK: Citation

    func testACitationWithADOIUsesTwoAuthorsTheYearAndTheDOI() {
        XCTAssertEqual(
            PaperNoteSlots.citation(title: "T", author: "Item Author", bibliography: .init(doi: "10.1234/abcd", authors: ["Smith", "Jones"], year: 2021)),
            "Smith, Jones · 2021 · doi:10.1234/abcd"
        )
    }

    func testMoreThanTwoAuthorsEndsInEtAl() {
        XCTAssertEqual(
            PaperNoteSlots.citation(title: "T", author: nil, bibliography: .init(doi: "10.1/x", authors: ["Smith", "Jones", "Lee"], year: 2020)),
            "Smith, Jones et al. · 2020 · doi:10.1/x"
        )
    }

    func testAnArXivIdStandsInForAMissingDOI() {
        XCTAssertEqual(
            PaperNoteSlots.citation(title: "T", author: nil, bibliography: .init(doi: "  ", arxivId: "2101.00001", authors: ["Smith"])),
            "Smith · arXiv:2101.00001"
        )
    }

    func testAnIdentifierWithNoAuthorsUsesTheItemsAuthorOrNone() {
        XCTAssertEqual(PaperNoteSlots.citation(title: "T", author: "Ann Lee", bibliography: .init(doi: "10.1/x", year: 2019)), "Ann Lee · 2019 · doi:10.1/x")
        XCTAssertEqual(PaperNoteSlots.citation(title: "T", author: nil, bibliography: .init(doi: "10.1/x")), "doi:10.1/x")
    }

    func testWithoutAnIdentifierTheCitationIsTitleAndAuthor() {
        XCTAssertEqual(PaperNoteSlots.citation(title: "Sleep and memory", author: "Ann Lee", bibliography: nil), "Sleep and memory · Ann Lee")
        XCTAssertEqual(
            PaperNoteSlots.citation(title: "Sleep and memory", author: "Item", bibliography: .init(authors: ["Smith", "Jones"], year: 2021)),
            "Sleep and memory · Item", "without an identifier the line is the item's title and author (Design)"
        )
    }

    func testWithNoAuthorAtAllTheCitationIsTheTitle() {
        XCTAssertEqual(PaperNoteSlots.citation(title: "Sleep and memory", author: nil, bibliography: nil), "Sleep and memory")
        XCTAssertEqual(PaperNoteSlots.citation(title: "Sleep and memory", author: "   ", bibliography: .init(authors: ["", " "])), "Sleep and memory")
    }

    func testWhitespaceInTheTitleAndAuthorsIsCollapsed() {
        XCTAssertEqual(PaperNoteSlots.citation(title: " Sleep\n and  memory ", author: "Ann\tLee", bibliography: nil), "Sleep and memory · Ann Lee")
    }

    func testAnEmptyTitleFallsBackToTheBibliographyTitle() {
        XCTAssertEqual(PaperNoteSlots.citation(title: "", author: nil, bibliography: .init(title: "From metadata")), "From metadata")
        XCTAssertEqual(PaperNoteSlots.citation(title: "", author: nil, bibliography: nil), "Untitled")
    }

    // MARK: Words

    func testTheWordsMatchTheDesign() {
        XCTAssertEqual(PaperNoteRole.allCases.map(PaperNoteSlots.slotName), ["Purpose", "Key findings", "Evidence"])
        XCTAssertEqual(PaperNoteRole.allCases.map(PaperNoteSlots.roleName), ["Purpose", "Key finding", "Evidence"])
        XCTAssertEqual(PaperNoteSlots.chooseTitle(.purpose), "Choose a Margin for Purpose")
        XCTAssertEqual(PaperNoteSlots.question(.evidence), "What supports a finding? Mention where it is.")
    }

    /// A Margin moved with no place (#4233) has a zero anchor; the section shows "No place", never "p. 1".
    func testAMarginWithNoPlaceShowsNoPage() {
        var placeless = margin("a", .purpose, at: 0)
        placeless.movedOrigin = MovedMarginOrigin(
            marginId: "a", itemId: "p1", sessionId: "s", liveMarginId: "live", fromLiveSessionId: "ls",
            fromLiveSessionTitle: "Walk", markedAt: Date(timeIntervalSince1970: 1), movedAt: Date(timeIntervalSince1970: 2),
            placeKnown: false)
        let answer = slots([placeless]).choices[0]
        XCTAssertNil(answer.page)
        XCTAssertNotEqual(answer.placeLine, "p. 1")
    }
}
