import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #4762: the Library's Filter and Sort chips sit side by side when both fit, stack when they don't, and always stack
/// at accessibility sizes. Two 100 × 40 pt stand-ins: a row is 40 pt tall, a column 40 + 8 + 40.
@MainActor
final class LibraryChipRowLayoutTests: XCTestCase {
    private func height(width: CGFloat, forcesColumn: Bool) -> CGFloat {
        let view = LibraryChipRowLayout(spacing: 8, forcesColumn: forcesColumn) {
            Color.clear.frame(width: 100, height: 40)
            Color.clear.frame(width: 100, height: 40)
        }
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 2
        return renderer.uiImage?.size.height ?? 0
    }

    func testARowWhenBothFit() {
        XCTAssertEqual(height(width: 300, forcesColumn: false), 40)
    }

    func testAColumnWhenTheyDoNotFit() {
        XCTAssertEqual(height(width: 150, forcesColumn: false), 88)
    }

    func testAlwaysAColumnAtAccessibilitySizes() {
        XCTAssertEqual(height(width: 300, forcesColumn: true), 88)
    }
}
