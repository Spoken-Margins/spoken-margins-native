import Foundation
import XCTest
@testable import SessionKit

/// #3830: the fixture `SupertonicSpeechTests.testASeamThatChangesTheSpokenArticleMatchesNoPreparedAudio` builds. That
/// test is app-hosted (Mac only), so its precondition is held here where the cloud can run it: a preface in front of
/// the article changes the article's spoken text only when a real tag opens in the preface and closes in the article.
/// A bare "<" before a space is a comparison, not a tag (#3813), and no longer reaches across the seam.
final class SpeechSeamFixtureTests: XCTestCase {
    static let filler = (1...8).map {
        "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk."
    }.joined(separator: " ")

    /// Shared with the app test, which copies these two strings.
    static let article = "id=intro > Results in every run. " + filler
    static let preface = "Overview. Cost <b class=cost\n\n"

    func testATagThatOpensInThePrefaceAndClosesInTheArticleChangesTheSpokenArticle() {
        let alone = NarrationChunkPlanner.articlePlan(Self.article).normalizedText
        let joined = SpeechTextNormalizer.normalize(Self.preface + Self.article)
        XCTAssertNotEqual(String(joined.suffix(alone.count)), alone, "the seam changes the spoken article")
    }

    func testAComparisonSignInThePrefaceNeverReachesIntoTheArticle() {
        let article = "Results > baseline in every run. " + Self.filler
        let alone = NarrationChunkPlanner.articlePlan(article).normalizedText
        let joined = SpeechTextNormalizer.normalize("Overview. Cost < quality for these agents.\n\n" + article)
        XCTAssertEqual(String(joined.suffix(alone.count)), alone, "comparison signs keep their words, so this is no seam")
    }
}
