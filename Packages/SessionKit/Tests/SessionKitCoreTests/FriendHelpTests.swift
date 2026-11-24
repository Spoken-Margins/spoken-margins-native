import XCTest
@testable import SessionKit
import SessionKitTestInputs

final class FriendHelpTests: XCTestCase {
    func testTheTopicsAreTheTenQuestionsInArrivalOrder() {
        XCTAssertEqual(FriendHelpTopic.allCases.map(\.rawValue),
                       ["what", "app", "wont-open", "where", "cant-hear", "add-episode", "misplaced", "answer", "who-hears", "remove"])
        XCTAssertEqual(Set(FriendHelpTopic.allCases.map(\.id)).count, FriendHelpTopic.allCases.count)
    }

    /// A receiver doesn't know our words, so neither the questions nor the answers use them (#5268).
    func testNoQuestionOrAnswerUsesAnInternalWord() {
        let banned = ["packet", "layer", "import", "anchor", "manifest", "session", "source"]
        for topic in FriendHelpTopic.allCases {
            XCTAssertTrue(topic.question.hasSuffix("?"), topic.rawValue)
            for text in [topic.question, topic.appAnswer] {
                for word in banned {
                    XCTAssertNil(text.range(of: word, options: .caseInsensitive), "\(topic.rawValue) says \"\(word)\"")
                }
                XCTAssertFalse(text.contains("’"), "\(topic.rawValue) has a curly apostrophe")
            }
        }
    }

    /// The item screen's friend button reads "Skip to …" or "Hear …'s Margins first"; the answer must fit both.
    func testWhereDoesNotNameOnlyOneOfTheFriendButtons() {
        XCTAssertFalse(FriendHelpTopic.where.appAnswer.contains("Skip to"))
    }

    /// The site page asks the same questions, in the same order, under the same anchors as the app.
    func testTheSitePageAsksTheSameQuestionsUnderTheSameAnchors() throws {
        let page = String(decoding: try TestInputs.data(.site, "friends/index.html"), as: UTF8.self)
        XCTAssertEqual(Self.siteHeadings(page), FriendHelpTopic.allCases.map { "<h2 id=\"\($0.rawValue)\">\($0.question)</h2>" })
    }

    func testTheSiteCheckFailsWhenAQuestionDrifts() throws {
        let page = String(decoding: try TestInputs.data(.site, "friends/index.html"), as: UTF8.self)
        let drifted = page.replacingOccurrences(of: ">Who hears my answer?<", with: ">Who can hear my answer?<")
        XCTAssertNotEqual(drifted, page)
        XCTAssertNotEqual(Self.siteHeadings(drifted), FriendHelpTopic.allCases.map { "<h2 id=\"\($0.rawValue)\">\($0.question)</h2>" })
    }

    func testEveryOpenFailureRowOpensTheWontOpenQuestion() {
        for row in PacketOpenFailureSheetContent.Row.allCases {
            XCTAssertEqual(FriendHelpTopic.forOpenFailure(PacketOpenFailureSheetContent(row: row)), .wontOpen, "\(row)")
        }
        XCTAssertEqual(PacketOpenFailureSheetContent.Row.allCases.count, 12)
    }

    /// Every `<h2 id=…>…</h2>` on the page, in order.
    private static func siteHeadings(_ page: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "<h2 id=\"[^\"]*\">[^<]*</h2>")
        return regex.matches(in: page, range: NSRange(page.startIndex..., in: page)).map { String(page[Range($0.range, in: page)!]) }
    }
}
