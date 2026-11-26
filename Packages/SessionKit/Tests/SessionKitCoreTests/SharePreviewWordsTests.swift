import XCTest
@testable import SessionKit

/// The recipient preview never shows a packet code (#5336). Each row pins the words, so a reword is a deliberate edit.
final class SharePreviewWordsTests: XCTestCase {
    private let allKinds: [SharedInterjectionRepresentationKind] = [
        .originalAudioAndText, .cleanedAudioAndText, .textOnly, .summaryText, .summaryAudioAndText, .ttsAudioAndText,
    ]
    private let allProvenances: [PortableSummaryProvenance] = [
        .publisherSupplied, .senderAuthored, .deterministic, .modelGenerated,
    ]

    func testEveryVersionHasPlainWordsMatchingTheCards() {
        XCTAssertEqual(SharePreviewWords.version(.originalAudioAndText), "As recorded")
        XCTAssertEqual(SharePreviewWords.version(.cleanedAudioAndText), "Without ums")
        XCTAssertEqual(SharePreviewWords.version(.textOnly), "Words only")
        XCTAssertEqual(SharePreviewWords.version(.summaryText), "Summary, words only")
        XCTAssertEqual(SharePreviewWords.version(.summaryAudioAndText), "Spoken summary")
        XCTAssertEqual(SharePreviewWords.version(.ttsAudioAndText), "Read by the phone's voice")
        XCTAssertEqual(SharePreviewWords.version(nil), "Version unavailable")
    }

    func testNoVersionOrSummarySourceShowsItsPacketCode() {
        for kind in allKinds {
            let words = SharePreviewWords.version(kind)
            XCTAssertNotEqual(words, kind.rawValue, "\(kind)")
            XCTAssertFalse(words.contains("_"), "\(kind) reads \(words)")
        }
        for provenance in allProvenances {
            let words = SharePreviewWords.summarySource(provenance)
            XCTAssertNotEqual(words, provenance.rawValue, "\(provenance)")
            XCTAssertFalse(words.contains("_"), "\(provenance) reads \(words)")
            XCTAssertNotEqual(words, provenance.rawValue.replacingOccurrences(of: "_", with: " "), "\(provenance)")
        }
        // Every packet value is in the tables above: a new one must be added there and given words.
        XCTAssertEqual(Set(allKinds.map(\.rawValue)).count, 6)
        XCTAssertEqual(SharePreviewWords.summarySource(nil), "source unknown")
    }
}
