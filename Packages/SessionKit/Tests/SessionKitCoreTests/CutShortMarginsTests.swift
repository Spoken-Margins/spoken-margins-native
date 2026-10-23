import XCTest
@testable import SessionKit

final class CutShortMarginsTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "cut-short-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "cut-short-margins.json")
    }

    func testAMarkSurvivesARelaunch() {
        let file = tempFile()
        CutShortMargins(fileURL: file).set(.interrupted, sessionId: "s1", interjectionId: "m-1")
        let reopened = CutShortMargins(fileURL: file)
        XCTAssertEqual(reopened.mark(sessionId: "s1", interjectionId: "m-1"), .interrupted)
    }

    func testMarginIdsThatRepeatInAnotherSessionAreNotConfused() {
        let marks = CutShortMargins(fileURL: tempFile())
        marks.set(.headphonesDisconnected, sessionId: "s1", interjectionId: "m-1")
        XCTAssertNil(marks.mark(sessionId: "s2", interjectionId: "m-1"))
    }

    func testClearingRemovesTheMarkForGoodAndReportsWhetherItDid() {
        let file = tempFile()
        let marks = CutShortMargins(fileURL: file)
        marks.set(.recovered, sessionId: "s1", interjectionId: "m-1")
        XCTAssertTrue(marks.clear(sessionId: "s1", interjectionId: "m-1"))
        XCTAssertFalse(marks.clear(sessionId: "s1", interjectionId: "m-1"))
        XCTAssertNil(CutShortMargins(fileURL: file).mark(sessionId: "s1", interjectionId: "m-1"))
    }

    func testAnUnreadableOrUnknownFileMeansNoMarksAndNoCrash() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(CutShortMargins(fileURL: file).mark(sessionId: "s1", interjectionId: "m-1"))
        try Data(#"{"s1::m-1":"somethingNewer","s1::m-2":"recovered"}"#.utf8).write(to: file)
        let marks = CutShortMargins(fileURL: file)
        XCTAssertNil(marks.mark(sessionId: "s1", interjectionId: "m-1"))
        XCTAssertEqual(marks.mark(sessionId: "s1", interjectionId: "m-2"), .recovered)
    }

    func testAMarkSetBeforeTheFileIsKnownIsKeptAndSavedOnceItIs() {
        let file = tempFile()
        let marks = CutShortMargins()
        XCTAssertFalse(marks.isConfigured)
        marks.set(.recovered, sessionId: "s1", interjectionId: "m-1")
        marks.use(fileURL: file)
        marks.use(fileURL: file)
        XCTAssertTrue(marks.isConfigured)
        XCTAssertEqual(CutShortMargins(fileURL: file).mark(sessionId: "s1", interjectionId: "m-1"), .recovered)
    }

    func testTheRowTagAndTheDetailLineDiffer() {
        XCTAssertEqual(CutShortMark.interrupted.tag, "Cut short")
        XCTAssertEqual(CutShortMark.recovered.tag, "Recovered")
        XCTAssertTrue(CutShortMark.headphonesDisconnected.explanation.contains("headphones"))
    }
}
