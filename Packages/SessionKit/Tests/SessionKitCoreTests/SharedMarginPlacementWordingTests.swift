import Foundation
import SessionKit
import SessionKitTestInputs
import XCTest

/// #1974: a recipient reads where a shared Margin sits in plain words, not an offset or an enum name.
final class SharedMarginPlacementWordingTests: XCTestCase {
    private let allClasses: [AnchorResolutionEvidenceClass] = [
        .exactEdition, .articleTextVerified, .transcriptVerified, .acousticVerified, .fused, .mapInterpolated,
        .timestampFallback, .recipientConfirmed, .ambiguous, .absentFromRecipientEdition, .unresolved
    ]

    func testEachClassHasItsWording() {
        func line(_ evidence: AnchorResolutionEvidenceClass, isAmbiguous: Bool = false) -> String {
            SharedMarginPlacementWording.line(for: ImportedAnchorResolution(evidenceClass: evidence, isAmbiguous: isAmbiguous))
        }
        for placed in [AnchorResolutionEvidenceClass.exactEdition, .articleTextVerified, .transcriptVerified, .acousticVerified, .fused] {
            XCTAssertEqual(line(placed), "Placed here", "\(placed)")
        }
        XCTAssertEqual(line(.mapInterpolated), "Placed roughly here")
        XCTAssertEqual(line(.timestampFallback), "Placed roughly here")
        XCTAssertEqual(line(.recipientConfirmed), "Placed where you confirmed")
        for unplaced in [AnchorResolutionEvidenceClass.unresolved, .absentFromRecipientEdition, .ambiguous] {
            XCTAssertEqual(line(unplaced), "Couldn't place this one. Tap to listen anyway.", "\(unplaced)")
        }
        XCTAssertEqual(line(.acousticVerified, isAmbiguous: true), SharedMarginPlacementWording.couldntPlace,
                       "A resolution flagged ambiguous is not placed, whatever its class says")
    }

    func testATextOffsetReadsAsAParagraphNeverAsTheOffset() {
        let resolution = ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 18_342)
        XCTAssertEqual(SharedMarginPlacementWording.line(for: resolution, paragraph: 7), "Near paragraph 7")
        XCTAssertEqual(SharedMarginPlacementWording.line(for: resolution), "Placed here",
                       "With no paragraph the offset is not shown")
        XCTAssertEqual(SharedMarginPlacementWording.line(for: resolution, paragraph: 0), "Placed here")
        let unplaced = ImportedAnchorResolution(evidenceClass: .unresolved, localStartChar: 18_342)
        XCTAssertEqual(SharedMarginPlacementWording.line(for: unplaced, paragraph: 7), SharedMarginPlacementWording.couldntPlace)
    }

    /// Audit: an ambiguous podcast match still holds its strongest candidate's media time. The import sheet must
    /// not print it as if the Margin were placed there.
    func testTheImportSheetShowsAClockOnlyForAPlacedMargin() {
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, localMediaTimeMs: 754_000, isAmbiguous: true)
        XCTAssertEqual(SharedMarginPlacementWording.importSheetLine(for: ambiguous), SharedMarginPlacementWording.couldntPlace)
        let flaggedOnly = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 754_000, isAmbiguous: true)
        XCTAssertEqual(SharedMarginPlacementWording.importSheetLine(for: flaggedOnly), SharedMarginPlacementWording.couldntPlace)
        for evidence in [AnchorResolutionEvidenceClass.unresolved, .absentFromRecipientEdition] {
            let unplaced = ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: 754_000)
            XCTAssertEqual(SharedMarginPlacementWording.importSheetLine(for: unplaced), SharedMarginPlacementWording.couldntPlace)
        }
        let placed = ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 754_000)
        XCTAssertEqual(SharedMarginPlacementWording.importSheetLine(for: placed), "12:34")
        let text = ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: 18_342)
        XCTAssertEqual(SharedMarginPlacementWording.importSheetLine(for: text, paragraph: 7), "Near paragraph 7")
    }

    func testNoOutputShowsADigitRunOrAnEnumNameAndNoTwoDifferByOneWord() {
        var outputs: Set<String> = []
        for evidence in allClasses {
            for start in [nil, 18_342] as [Int?] {
                for paragraph in [nil, 12] as [Int?] {
                    let resolution = ImportedAnchorResolution(evidenceClass: evidence, localStartChar: start, localMediaTimeMs: 45_000)
                    outputs.insert(SharedMarginPlacementWording.line(for: resolution, paragraph: paragraph))
                }
            }
        }
        for output in outputs {
            let digitRuns = output.split(whereSeparator: { !$0.isNumber }).map(\.count)
            XCTAssertTrue((digitRuns.max() ?? 0) <= 3, output)
            XCTAssertFalse(output.contains("_"), output)
            XCTAssertFalse(output.contains("18342"), output)
            for evidence in allClasses {
                XCTAssertFalse(output.lowercased().contains(evidence.rawValue.replacingOccurrences(of: "_", with: " ")), output)
            }
        }
        // "Position matched" and "Position not matched" differed by one short word. The only pair here a single
        // word apart is the deliberate "roughly" qualifier, which is the meaning itself.
        let words = outputs.map { $0.split(separator: " ").map(String.init) }
        for (index, first) in words.enumerated() {
            for second in words[(index + 1)...] where wordDistance(first, second) < 2 {
                XCTAssertEqual(Set([first.joined(separator: " "), second.joined(separator: " ")]),
                               ["Placed here", "Placed roughly here"], "\(first) vs \(second)")
            }
        }
    }

    // MARK: - The copy-length note (#4175)

    private struct CopyLengthCase {
        let note: String
        let senderMs: Int?
        let listenerMs: Int?
        let expect: String
        let farApart: Bool?
        let amount: String?
    }

    /// The table the web's test reads too (`Contracts/fixtures/copy-length-note/cases.json`). A length JSON cannot hold
    /// ("Infinity", "NaN") and a null both read as nil here, never through `Double(...)`.
    private func copyLengthCases() throws -> [CopyLengthCase] {
        let data = try TestInputs.data(.contracts, "fixtures/copy-length-note/cases.json")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return rows.map { row in
            CopyLengthCase(
                note: row["note"] as? String ?? "", senderMs: row["senderMs"] as? Int, listenerMs: row["listenerMs"] as? Int,
                expect: row["expect"] as? String ?? "", farApart: row["farApart"] as? Bool, amount: row["amount"] as? String)
        }
    }

    func testTheCopyLengthRuleMatchesEveryRowOfTheSharedTable() throws {
        let cases = try copyLengthCases()
        XCTAssertGreaterThanOrEqual(cases.count, 15, "the shared table shrank")
        for row in cases {
            let difference = CopyLengthDifference(senderMs: row.senderMs, listenerMs: row.listenerMs)
            if row.expect == "none" {
                XCTAssertNil(difference, row.note)
            } else {
                XCTAssertEqual(difference?.direction.rawValue, row.expect, row.note)
                XCTAssertEqual(difference?.farApart, row.farApart, row.note)
                XCTAssertEqual(difference?.amount, row.amount, row.note)
            }
        }
    }

    func testTheNoteNamesTheSizeOfTheDifferenceInThreeSentences() {
        func line(_ sender: Int?, _ listener: Int?, _ subject: PinnedMarginCard.Subject, atSenderClock: Bool = true,
                  plan: SharedMarginPlacementPlan = .roughly(mediaTimeMs: 300_000)) -> String? {
            SharedMarginPlacementWording.pinnedCardLine(
                for: plan, atSenderClock: atSenderClock, senderCopyMs: sender, listenerCopyMs: listener, subject: subject)
        }
        // #4614's pair, a web packet at the sender's clock with no fingerprint (the web-packet device condition).
        XCTAssertEqual(line(1_946_018, 1_913_000, .friend("Cole")),
                       "Your copy is about 35 seconds shorter than Cole's, so Margins may be that far off.")
        XCTAssertEqual(line(1_946_018, 1_976_118, .friend("Cole")),
                       "Your copy is about 30 seconds longer than Cole's, so Margins may be that far off.")
        XCTAssertEqual(line(1_800_000, 600_000, .friend("Cole")),
                       "Your copy is about 20 minutes shorter than Cole's, so Margins may not line up.")
        XCTAssertEqual(line(1_800_000, 2_400_000, .friend("Cole")),
                       "Your copy is about 10 minutes longer than Cole's, so Margins may not line up.")
        // No name, a stand-in and a name too long for a button never stretch the card.
        XCTAssertEqual(line(1_946_018, 1_913_000, .friend(nil)),
                       "Your copy is about 35 seconds shorter than your friend's, so Margins may be that far off.")
        XCTAssertEqual(line(1_946_018, 1_913_000, .friend("A friend")),
                       "Your copy is about 35 seconds shorter than your friend's, so Margins may be that far off.")
        XCTAssertEqual(line(1_946_018, 1_913_000, .friend("Alexandria Bartholomew-Featherstonehaugh the Third")),
                       "Your copy is about 35 seconds shorter than Alexandria's, so Margins may be that far off.")
        XCTAssertEqual(line(1_946_018, 1_913_000, .friend("Bartholomew-Featherstonehaugh")),
                       "Your copy is about 35 seconds shorter than your friend's, so Margins may be that far off.")
    }

    func testTheGenericCautionStaysWhenThereIsNothingToSayAboutTheLengths() {
        let caution = SharedMarginPlacementWording.approximatePositionNote
        func line(_ sender: Int?, _ listener: Int?, atSenderClock: Bool = true) -> String? {
            SharedMarginPlacementWording.pinnedCardLine(
                for: .roughly(mediaTimeMs: 300_000), atSenderClock: atSenderClock, senderCopyMs: sender,
                listenerCopyMs: listener, subject: .friend("Cole"))
        }
        XCTAssertEqual(line(nil, 1_913_000), caution, "the sender's length is missing")
        XCTAssertEqual(line(1_946_018, nil), caution, "the player has not reported a length yet")
        XCTAssertEqual(line(0, 1_913_000), caution)
        XCTAssertEqual(line(1_800_000, 1_809_999), caution, "under 10 s apart")
        // A Margin shifted by its matched neighbours already has the ad difference taken out.
        XCTAssertEqual(line(1_946_018, 1_913_000, atSenderClock: false), caution)
        // An unknown place has no time to warn about, whatever the lengths say.
        for plan in [SharedMarginPlacementPlan.placed(mediaTimeMs: 1), .afterOthers, .notPlayable] {
            XCTAssertNil(SharedMarginPlacementWording.pinnedCardLine(
                for: plan, atSenderClock: true, senderCopyMs: 1_946_018, listenerCopyMs: 1_913_000, subject: .friend("Cole")),
                         "\(plan)")
        }
    }

    /// The card draws one line under its headline within a height budget (#3597), so the note stays short for the
    /// longest name a button carries and the biggest difference, and never prints an enum name.
    func testTheLongestNoteStaysShort() throws {
        for row in try copyLengthCases() where row.expect != "none" {
            let note = try XCTUnwrap(SharedMarginPlacementWording.pinnedCardLine(
                for: .roughly(mediaTimeMs: 1), atSenderClock: true, senderCopyMs: row.senderMs, listenerCopyMs: row.listenerMs,
                subject: .friend("Fourteen chars")), row.note)
            XCTAssertLessThanOrEqual(note.count, 100, "\(row.note): \(note)")
            XCTAssertFalse(note.contains("farApart"), row.note)
            XCTAssertTrue(note.contains(row.expect), row.note)
            XCTAssertTrue(note.contains(try XCTUnwrap(row.amount)), row.note)
        }
    }

    private func wordDistance(_ a: [String], _ b: [String]) -> Int {
        var previous = Array(0...b.count)
        for (i, wordA) in a.enumerated() {
            var row = [i + 1]
            for (j, wordB) in b.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (wordA == wordB ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }
}
