import XCTest
import SwiftUI
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

    /// Mounts the whole sheet: the reader tests above build the UITextView alone and cannot see
    /// a SwiftUI ancestor's identifier replace the text view's (#1426). SwiftUI vends its
    /// accessibility nodes lazily, so the XCUI hierarchy in J1 is the real check that the sheet
    /// identifier still exists; this test guards only the text view's identifier through the mounted sheet.
    func testMountedSheetKeepsTheTextViewIdentifier() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let text = "First sentence. Current sentence. Last sentence."
        let host = UIHostingController(rootView: NativeTextPeekView(
            title: "Article",
            target: PlaybackTextReaderTarget.resolve(text: text, chapters: [], offset: "First sentence. ".count)
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        var textView: UITextView?
        for _ in 0..<150 where textView == nil {
            host.view.layoutIfNeeded()
            textView = Self.subviews(of: host.view).compactMap { $0 as? UITextView }.first
            if textView == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let mountedTextView = try XCTUnwrap(textView, "The full-source reader never mounted its text view")
        XCTAssertEqual(mountedTextView.accessibilityIdentifier, NativeTextPeekView.textIdentifier)

        var found: [(identifier: String, node: NSObject)] = []
        var visited = Set<ObjectIdentifier>()
        Self.collectIdentifiers(from: host.view, into: &found, visited: &visited)
        XCTAssertTrue(found.contains { $0.identifier == NativeTextPeekView.textIdentifier },
                      "The text view must keep its identifier; saw \(found.map { $0.identifier })")
        XCTAssertFalse(found.contains { $0.identifier == NativeTextPeekView.sheetIdentifier && $0.node === mountedTextView },
                       "The sheet's identifier replaced the text view's")
    }

    private static func subviews(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { subviews(of: $0) }
    }

    /// Walks views and the accessibility elements SwiftUI vends, which are not always views.
    private static func collectIdentifiers(from node: NSObject, into found: inout [(identifier: String, node: NSObject)],
                                           visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        if node.responds(to: Selector(("accessibilityIdentifier"))),
           let identifier = node.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty {
            found.append((identifier, node))
        }
        var children: [NSObject] = []
        if let view = node as? UIView { children += view.subviews }
        children += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children { collectIdentifiers(from: child, into: &found, visited: &visited) }
    }
}
