import XCTest
@testable import DesktopCore

final class DesktopTextNavigationTests: XCTestCase {
    func testSentenceNavigationUsesSourceCharacterOffsets() {
        let text = "Listen 🧭 here. Then continue! Last thought?"
        let second = "Listen 🧭 here. ".count
        let third = "Listen 🧭 here. Then continue! ".count

        XCTAssertEqual(DesktopTextNavigation.nextSentence(after: 0, in: text), second)
        XCTAssertEqual(DesktopTextNavigation.nextSentence(after: second, in: text), third)
        XCTAssertEqual(DesktopTextNavigation.previousSentence(before: third, in: text), second)
        XCTAssertEqual(DesktopTextNavigation.previousSentence(before: second, in: text), 0)
        XCTAssertEqual(DesktopTextNavigation.nextSentence(after: 999, in: text), text.count)
        XCTAssertEqual(DesktopTextNavigation.previousSentence(before: -5, in: text), 0)
    }

    func testNoPunctuationStillHasBothEnds() {
        XCTAssertEqual(DesktopTextNavigation.nextSentence(after: 2, in: "Plain text"), 10)
        XCTAssertEqual(DesktopTextNavigation.previousSentence(before: 7, in: "Plain text"), 0)
    }
}
