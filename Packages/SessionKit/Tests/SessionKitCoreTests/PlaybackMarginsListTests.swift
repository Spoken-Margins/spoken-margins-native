import Foundation
import XCTest
@testable import SessionKit

/// The playback screen's Margins view lists this item's own and shared Margins together in source order (#450).
final class PlaybackMarginsListTests: XCTestCase {
    private typealias List = PlaybackMarginsList

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func own(
        _ id: String, itemID: String = "item", ms: Int? = nil, char: Int = 0, type: AnchorType = .media,
        target: InterjectionTargetType = .item, created: Double = 10
    ) -> MarginCollection.PrivateEntry {
        MarginCollection.PrivateEntry(
            interjection: Interjection(
                id: id, itemId: itemID, sessionId: "session", targetType: target, targetId: itemID,
                createdAt: date(created), roughPercent: 0,
                anchor: Anchor(anchorType: type, startChar: char, endChar: char + 1, anchorBefore: "", anchorAfter: "", mediaTimeMs: ms),
                audioPath: nil, audioStatus: "missing", transcriptionStatus: "complete", transcript: "words",
                cleanedTranscript: nil, displayText: nil, status: "active"
            ),
            itemTitle: "Title", sessionDate: nil
        )
    }

    private func shared(
        _ id: String, itemID: String? = "item", senderMs: Int? = nil, senderChar: Int? = nil,
        resolution: ImportedAnchorResolution = .init(evidenceClass: .unresolved), created: Double = 10
    ) -> MarginCollection.SharedEntry {
        MarginCollection.SharedEntry(
            interjection: ImportedCommentaryInterjection(
                id: id, layerId: "layer", packageScopedId: id, createdAt: date(created),
                anchorEvidence: PortableAnchorEvidence(anchorType: senderChar == nil ? .media : .text, startChar: senderChar, mediaTimeMs: senderMs),
                approvedTranscript: "words", resolution: resolution
            ),
            layer: ImportedCommentaryLayer(
                id: "layer", itemId: itemID, packageDigest: "digest", packageId: "packet",
                itemIdentity: SharedItemIdentity(itemType: .text, title: "Packet title"), importedAt: date(1), deletedAt: nil
            ),
            itemTitle: "Title"
        )
    }

    private func entries(own: [MarginCollection.PrivateEntry] = [], shared: [MarginCollection.SharedEntry] = []) -> MarginCollection.Entries {
        MarginCollection.Entries(privateRows: own, sharedRows: shared)
    }

    private func ids(_ rows: [List.Row]) -> [String] { rows.map(\.id) }

    // MARK: Which Margins

    func testNoMarginsListsNothingUnderEveryFilter() {
        for filter in List.Filter.allCases {
            XCTAssertEqual(List.rows(itemID: "item", entries: entries(), filter: filter), [])
        }
        XCTAssertEqual(List.counts(itemID: "item", entries: entries()), .init(all: 0, mine: 0, shared: 0))
    }

    func testOnlyOwnMarginsShowUnderAllAndMineAndNothingUnderShared() {
        let list = entries(own: [own("b", ms: 20_000), own("a", ms: 5_000)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::a", "session::b"])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .mine)), ["session::a", "session::b"])
        XCTAssertEqual(List.rows(itemID: "item", entries: list, filter: .shared), [])
        XCTAssertEqual(List.counts(itemID: "item", entries: list), .init(all: 2, mine: 2, shared: 0))
    }

    func testOnlySharedMarginsShowUnderAllAndSharedAndNothingUnderMine() {
        let list = entries(shared: [shared("s", senderMs: 9_000)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["shared::layer::s"])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .shared)), ["shared::layer::s"])
        XCTAssertEqual(List.rows(itemID: "item", entries: list, filter: .mine), [])
        XCTAssertEqual(List.counts(itemID: "item", entries: list), .init(all: 1, mine: 0, shared: 1))
    }

    func testBothKindsAreMergedInSourceOrderUnderAll() {
        let list = entries(
            own: [own("late", ms: 300_000), own("early", ms: 10_000)],
            shared: [shared("mid", senderMs: 120_000), shared("first", senderMs: 1_000)]
        )
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)),
                       ["shared::layer::first", "session::early", "shared::layer::mid", "session::late"])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .mine)), ["session::early", "session::late"])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .shared)), ["shared::layer::first", "shared::layer::mid"])
        XCTAssertEqual(List.counts(itemID: "item", entries: list), .init(all: 4, mine: 2, shared: 2))
    }

    func testMarginsOfOtherItemsAndUnattachedPacketsAreLeftOut() {
        let list = entries(
            own: [own("here", ms: 1_000), own("there", itemID: "other", ms: 1_000)],
            shared: [shared("here", senderMs: 2_000), shared("there", itemID: "other", senderMs: 2_000), shared("loose", itemID: nil, senderMs: 2_000)]
        )
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::here", "shared::layer::here"])
        XCTAssertEqual(List.counts(itemID: "item", entries: list).all, 2)
    }

    // MARK: Order

    func testOwnComesBeforeSharedAtTheSamePosition() {
        let list = entries(own: [own("mine", ms: 60_000, created: 50)], shared: [shared("theirs", senderMs: 60_000, created: 1)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::mine", "shared::layer::theirs"])
    }

    func testSamePositionAndKindGoesByAgeThenId() {
        let list = entries(own: [own("c", ms: 5_000, created: 30), own("b", ms: 5_000, created: 20), own("a", ms: 5_000, created: 20)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::a", "session::b", "session::c"])
    }

    func testSourceOrderBeatsRecordingOrder() {
        let list = entries(own: [own("recordedFirstButLater", ms: 90_000, created: 1), own("recordedLastButEarlier", ms: 4_000, created: 99)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::recordedLastButEarlier", "session::recordedFirstButLater"])
    }

    func testTextMarginsGoByCharacterOffset() {
        let list = entries(
            own: [own("two", char: 800, type: .text), own("zero", char: 0, type: .text)],
            shared: [shared("one", senderChar: 300), shared("matched", senderChar: 5, resolution: .init(evidenceClass: .articleTextVerified, localStartChar: 500))]
        )
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)),
                       ["session::zero", "shared::layer::one", "shared::layer::matched", "session::two"])
    }

    func testMarginsWithNoPositionComeLastInTheSameOrder() {
        let list = entries(
            own: [own("n2", created: 7), own("n1", created: 7), own("timed", ms: 70_000)],
            shared: [shared("lost", created: 1), shared("placed", senderMs: 1_000)]
        )
        let rows = List.rows(itemID: "item", entries: list, filter: .all)
        XCTAssertEqual(ids(rows), ["shared::layer::placed", "session::timed", "session::n1", "session::n2", "shared::layer::lost"])
        XCTAssertEqual(rows.suffix(3).map(\.position), [nil, nil, nil])
    }

    func testMarginsOnAssistantAndSummaryTurnsAreNotListedOrCounted() {
        let list = entries(own: [
            own("turn", ms: 5_000, target: .assistantTurn),
            own("summary", char: 10, type: .text, target: .summaryTurn),
            own("source", ms: 9_000)
        ])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::source"])
        XCTAssertEqual(List.counts(itemID: "item", entries: list), .init(all: 1, mine: 1, shared: 0))
    }

    func testATextMatchOnlyCountsAsExactForTheClassesThatPlaceIt() {
        let classes: [(AnchorResolutionEvidenceClass, Bool)] = [
            (.articleTextVerified, false), (.exactEdition, false), (.recipientConfirmed, false),
            (.mapInterpolated, true), (.timestampFallback, true), (.transcriptVerified, true),
            (.absentFromRecipientEdition, true), (.unresolved, true)
        ]
        for (evidenceClass, approximate) in classes {
            let row = shared("s", senderChar: 5, resolution: .init(evidenceClass: evidenceClass, localStartChar: 500))
            let rows = List.rows(itemID: "item", entries: entries(shared: [row]), filter: .all)
            XCTAssertEqual(rows.first?.isApproximate, approximate, "\(evidenceClass)")
        }
    }

    func testOwnTextMarginWithoutATimeUsesItsOffsetButAMediaAnchorWithoutOneHasNone() {
        let list = entries(own: [own("text", ms: nil, char: 40, type: .text), own("media", ms: nil, char: 40, type: .media)])
        let rows = List.rows(itemID: "item", entries: list, filter: .mine)
        XCTAssertEqual(rows.first(where: { $0.id == "session::text" })?.position, .charOffset(40))
        XCTAssertNil(rows.first(where: { $0.id == "session::media" })?.position)
    }

    func testTimeZeroIsAPositionAndNegativeValuesAreNot() {
        let list = entries(own: [own("zero", ms: 0), own("neg", ms: -5, char: -1, type: .text)])
        let rows = List.rows(itemID: "item", entries: list, filter: .all)
        XCTAssertEqual(ids(rows), ["session::zero", "session::neg"])
        XCTAssertEqual(rows[0].position, .mediaTimeMs(0))
        XCTAssertNil(rows[1].position)
    }

    func testTimesSortBeforeOffsetsWhenAnItemMixesThem() {
        let list = entries(own: [own("char", char: 3, type: .text), own("time", ms: 900_000)])
        XCTAssertEqual(ids(List.rows(itemID: "item", entries: list, filter: .all)), ["session::time", "session::char"])
    }

    // MARK: Shared positions

    func testASharedMarginSitsWhereThePlayButtonWouldPlayIt() {
        let verified = shared("v", senderMs: 302_926, resolution: .init(evidenceClass: .acousticVerified, localMediaTimeMs: 332_900))
        let interpolated = shared("i", senderMs: 302_926, resolution: .init(evidenceClass: .mapInterpolated, localMediaTimeMs: 322_900))
        let fallback = shared("f", senderMs: 302_926)
        let rows = List.rows(itemID: "item", entries: entries(shared: [verified, interpolated, fallback]), filter: .shared)
        XCTAssertEqual(rows.map(\.position), [.mediaTimeMs(302_926), .mediaTimeMs(322_900), .mediaTimeMs(332_900)])
        XCTAssertEqual(rows.map(\.isApproximate), [true, true, false])
    }

    func testAnAmbiguousTextMatchFallsBackToTheSendersOffsetAsApproximate() {
        let ambiguous = shared("a", senderChar: 120, resolution: .init(evidenceClass: .articleTextVerified, localStartChar: 900, isAmbiguous: true))
        let rows = List.rows(itemID: "item", entries: entries(shared: [ambiguous]), filter: .all)
        XCTAssertEqual(rows.first?.position, .charOffset(120))
        XCTAssertEqual(rows.first?.isApproximate, true)
    }

    func testAVerifiedTextMatchIsNotApproximateButAnInterpolatedOneIs() {
        let verified = shared("v", senderChar: 1, resolution: .init(evidenceClass: .articleTextVerified, localStartChar: 500))
        let interpolated = shared("i", senderChar: 1, resolution: .init(evidenceClass: .mapInterpolated, localStartChar: 600))
        let rows = List.rows(itemID: "item", entries: entries(shared: [verified, interpolated]), filter: .all)
        XCTAssertEqual(rows.map(\.isApproximate), [false, true])
    }

    func testOwnMarginsAreNeverApproximate() {
        XCTAssertEqual(List.rows(itemID: "item", entries: entries(own: [own("a", ms: 1)]), filter: .all).map(\.isApproximate), [false])
    }

    func testFilterTitles() {
        XCTAssertEqual(List.Filter.allCases.map(\.title), ["All", "Mine", "Shared"])
    }
}
