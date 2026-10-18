import Foundation
import SessionKit
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
            XCTAssertEqual(line(unplaced), "Couldn’t place this one. Tap to listen anyway.", "\(unplaced)")
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
