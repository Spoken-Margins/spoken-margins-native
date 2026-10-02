import XCTest
@testable import SessionKit

/// #358: URL and email fragments left by PDF extraction were read aloud as words.
final class SpeechLinkFragmentTests: XCTestCase {
    func testURLFragmentFromThe2607PaperIsSpokenAsLink() {
        let source = "the ACL code of ethics (\nportal/content/acl-code-ethics) applies."
        XCTAssertEqual(SpeechTextNormalizer.normalize(source), "the ACL code of ethics ( link) applies.")
    }

    func testEmailFragmentFromTheTitlePageIsSpokenAsEmail() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("Jane Doe, KIT\n@alumni.\nAbstract"), "Jane Doe, KIT email. Abstract")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Write to jane.doe@kit.edu for data."), "Write to email for data.")
    }

    func testParenthesesLeftEmptyByARemovedURLAreDropped() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("See the code (https://github.com/a/b) here."), "See the code here.")
        XCTAssertEqual(SpeechTextNormalizer.normalize("Data [ www.example.org ] is open."), "Data is open.")
    }

    func testDatesFractionsAndLoneSymbolsAreLeftAlone() {
        XCTAssertEqual(SpeechTextNormalizer.normalize("On 1/2/2024 we met @ 5pm, and/or later."), "On 1/2/2024 we met @ 5pm, and/or later.")
    }

    /// Found by running the change over the C1 corpus: slash lists in papers are science, not links.
    func testSlashListsAndUnitsInPapersStayWords() {
        for text in ["Live/CD31−/CD45−/CD326+ cells", "T/NK/ILC subsets", "the p53/Mdm2/Mdmx loop",
                     "MAPK/Erk1/2 signalling", "fields of 5 v/cm/mm", "grant 102905/Z/13/Z", "Deter/accelerate/delay"] {
            XCTAssertEqual(SpeechTextNormalizer.normalize(text), text, text)
        }
        // Whole domains were already removed silently before this change, and still are.
        XCTAssertEqual(SpeechTextNormalizer.normalize("Published at royalsocietypublishing.org/journal/rsos today."), "Published at today.")
        XCTAssertTrue(SpeechTextNormalizer.looksLikeURLPath("journals/rsos/10.1098.x"))
        XCTAssertTrue(SpeechTextNormalizer.looksLikeURLPath("portal/content/acl-code-ethics."))
    }

    func testSpokenOffsetsStillMapToTheSource() throws {
        let source = "Ethics (\nportal/content/acl-code-ethics) matter."
        let projected = SpeechTextNormalizer.normalizeWithSourceOffsets(source)
        let linkStart = try XCTUnwrap(projected.text.range(of: "link")).lowerBound
        let spokenOffset = projected.text.distance(from: projected.text.startIndex, to: linkStart)
        XCTAssertEqual(projected.sourceOffset(atSpokenCharacterOffset: spokenOffset), source.distance(from: source.startIndex, to: try XCTUnwrap(source.range(of: "portal")).lowerBound))
        XCTAssertEqual(projected.text, "Ethics ( link) matter.", "the line break inside the parenthesis stays a (silent) space")
    }

    func testImportedTextCleaningKeepsAddresses() {
        XCTAssertTrue(SpeechTextNormalizer.normalizeImportedText("Write to jane.doe@kit.edu for data.").contains("@"))
    }
}
