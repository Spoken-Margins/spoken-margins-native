import XCTest
@testable import SessionKit

final class DiscussionContextProviderBytesTests: XCTestCase {
    func testSummaryProviderBytesMatchPreExtractionFixture() {
        // Captured by executing the pre-extraction builder from ce9de1f5 with this
        // fixed input on Swift 6.2.4/Linux. The Mac lane must verify Darwin's bytes.
        let expected = """
        {
          "currentFollowUp" : null,
          "interjections" : [

          ],
          "item" : {
            "text" : "Body",
            "title" : "Article"
          },
          "listeningMap" : {
            "chapters" : [
              {
                "endChar" : 4,
                "startChar" : 0,
                "title" : "Opening"
              }
            ],
            "overview" : "Overview"
          },
          "primaryUserIntent" : null,
          "recentTurns" : [

          ],
          "schemaVersion" : "session-export.v1"
        }
        """
        let actual = DiscussionContext.contextJSON(
            itemTitle: "Article", itemText: "Body", overview: "Overview",
            chapters: [Chapter(id: "chapter", title: "Opening", startChar: 0, endChar: 4, percent: 0)],
            turns: [], currentTargetType: TargetType.itemTextTTS.rawValue, currentTargetId: "item",
            interjections: [], currentFollowUp: nil
        )
        XCTAssertEqual(actual, expected)
    }
}
