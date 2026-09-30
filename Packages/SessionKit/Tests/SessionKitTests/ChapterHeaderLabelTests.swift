import XCTest
@testable import SessionKit

final class ChapterHeaderLabelTests: XCTestCase {
    func testTitlesThatStartWithANumberAreNotNumberedAgain() {
        XCTAssertEqual(ChapterHeaderLabel.title("7 Conclusion", index: 7), "7 Conclusion")
        XCTAssertEqual(ChapterHeaderLabel.title("1 INTRODUCTION", index: 0), "1 INTRODUCTION")
        XCTAssertEqual(ChapterHeaderLabel.title(" 12. Epilogue ", index: 11), "12. Epilogue")
    }

    func testTitlesThatNameTheirChapterAreNotNumberedAgain() {
        XCTAssertEqual(ChapterHeaderLabel.title("Chapter 3", index: 2), "Chapter 3")
        XCTAssertEqual(ChapterHeaderLabel.title("CHAPTER IV: The Storm", index: 3), "CHAPTER IV: The Storm")
        XCTAssertEqual(ChapterHeaderLabel.title("Chapter One", index: 0), "Chapter One")
        XCTAssertEqual(ChapterHeaderLabel.title("Ch. 5 Return", index: 4), "Ch. 5 Return")
    }

    func testUnnumberedTitlesKeepTheChapterNumber() {
        XCTAssertEqual(ChapterHeaderLabel.title("The Pivot", index: 1), "Ch. 2: The Pivot")
        XCTAssertEqual(ChapterHeaderLabel.title("Chapters of My Life", index: 0), "Ch. 1: Chapters of My Life")
        XCTAssertEqual(ChapterHeaderLabel.title("Chair Yoga", index: 2), "Ch. 3: Chair Yoga")
    }
}
