import XCTest
import UIKit
import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class NativeTextReaderViewTests: XCTestCase {
    func testReaderShowsTheStartOfALongSentenceAtAccessibilityTextSize() throws {
        let preface = (1...40).map { "Earlier sentence \($0)." }.joined(separator: "\n\n")
        let longSentence = "Long sentence " + String(repeating: "with selectable words ", count: 13) + "."
        let text = preface + "\n\n" + longSentence + " A later sentence follows."
        let offset = preface.count + 2
        var index = PlaybackLivePassage.Index(text: text)
        index.update(offset: offset)
        let reader = try XCTUnwrap(index.chapter).reader(at: offset)
        let view = NativeTextReaderView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        view.display(reader, font: .systemFont(ofSize: 44))
        view.layoutIfNeeded()
        let sentence = try XCTUnwrap(reader.currentSentenceRange)
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: sentence.location))
        XCTAssertTrue(view.bounds.intersects(view.caretRect(for: position)), "Opening must show the beginning even when the sentence exceeds the viewport")
        XCTAssertNotNil(view.attributedText.attribute(.backgroundColor, at: sentence.location + sentence.length - 1, effectiveRange: nil), "The complete sentence stays highlighted")
    }

    func testReaderScrollsToTheLateSentenceAfterLayoutAndKeepsUserSelectionOnUpdates() throws {
        let text = (1...90).map { "Sentence \($0) is selectable with the rest of this chapter." }.joined(separator: "\n\n")
        let start = try XCTUnwrap(text.range(of: "Sentence 80"))
        let offset = text.distance(from: text.startIndex, to: start.lowerBound)
        var index = PlaybackLivePassage.Index(text: text)
        index.update(offset: offset)
        let reader = try XCTUnwrap(index.chapter).reader(at: offset)
        let view = NativeTextReaderView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let font = UIFont.systemFont(ofSize: 18)
        view.display(reader, font: font)
        view.layoutIfNeeded()
        XCTAssertEqual(view.text, text)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertGreaterThan(view.contentOffset.y, 1_000, "The existing reader must open near the late sentence, not chapter start")
        let sentence = try XCTUnwrap(reader.currentSentenceRange)
        let position = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: sentence.location))
        let caret = view.caretRect(for: position)
        XCTAssertTrue(view.bounds.intersects(caret), "The highlighted sentence start should be visible after layout")
        XCTAssertNotNil(view.attributedText.attribute(.backgroundColor, at: sentence.location, effectiveRange: nil))

        let selection = NSRange(location: 0, length: 120)
        view.selectedRange = selection
        view.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        let scrolled = view.contentOffset
        view.display(reader, font: font)
        view.layoutIfNeeded()
        XCTAssertEqual(view.selectedRange, selection, "A normal SwiftUI update must preserve a multi-sentence selection")
        XCTAssertEqual(view.contentOffset, scrolled, "The initial scroll must not run again after the listener browses")
    }
}
