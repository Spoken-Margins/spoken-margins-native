import SessionKit
import XCTest

/// #4338, PR 4: where a page note and a highlight's corners go, in the page's own space.
final class PDFCommentGeometryTests: XCTestCase {
    private let page = CGRect(x: 0, y: 0, width: 612, height: 792)

    func testAnUprightPagePutsTheFirstNoteAtItsTopLeftAndStacksTheNextBelow() {
        let first = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 0, slot: 0)
        let second = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 0, slot: 1)

        XCTAssertEqual(first, CGRect(x: 18, y: 792 - 18 - 24, width: 24, height: 24))
        XCTAssertEqual(second.minX, first.minX)
        XCTAssertEqual(first.minY - second.minY, 30, "one note's height and the gap, further down")
        XCTAssertFalse(first.intersects(second))
    }

    func testEveryRotationPutsTheNoteAtTheTopLeftOfThePageAsDrawn() {
        // Each rotation's own corner, and the direction that is "down" on the screen in the page's own space.
        let cases: [(rotation: Int, corner: CGPoint, down: (dx: CGFloat, dy: CGFloat))] = [
            (0, CGPoint(x: 0, y: 792), (dx: 0, dy: -1)),
            (90, CGPoint(x: 0, y: 0), (dx: 1, dy: 0)),
            (180, CGPoint(x: 612, y: 0), (dx: 0, dy: 1)),
            (270, CGPoint(x: 612, y: 792), (dx: -1, dy: 0)),
        ]
        for row in cases {
            let note = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: row.rotation, slot: 0)
            XCTAssertTrue(page.contains(note), "rotation \(row.rotation): the note is on the page")
            // The note's nearest corner to the page's visual top-left corner is 18 away along both page edges.
            let nearX = abs(note.minX - row.corner.x) < abs(note.maxX - row.corner.x) ? note.minX : note.maxX
            let nearY = abs(note.minY - row.corner.y) < abs(note.maxY - row.corner.y) ? note.minY : note.maxY
            XCTAssertEqual(abs(nearX - row.corner.x), 18, accuracy: 0.001, "rotation \(row.rotation) x")
            XCTAssertEqual(abs(nearY - row.corner.y), 18, accuracy: 0.001, "rotation \(row.rotation) y")

            let next = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: row.rotation, slot: 1)
            XCTAssertEqual(next.minX - note.minX, row.down.dx * 30, accuracy: 0.001, "rotation \(row.rotation): the next note is 'down'")
            XCTAssertEqual(next.minY - note.minY, row.down.dy * 30, accuracy: 0.001)
            XCTAssertFalse(note.intersects(next))
        }
    }

    func testRotationsOutsideZeroTo270AreTurnedIntoOneOfTheFour() {
        let upright = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 0, slot: 0)
        XCTAssertEqual(PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 360, slot: 0), upright)
        XCTAssertEqual(PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 720, slot: 0), upright)
        XCTAssertEqual(
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: -90, slot: 0),
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 270, slot: 0)
        )
        XCTAssertEqual(
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 450, slot: 0),
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 90, slot: 0)
        )
    }

    func testAPageWhoseBoundsDoNotStartAtTheOriginIsOffsetByThem() {
        let shifted = CGRect(x: 10, y: 20, width: 300, height: 400)
        let note = PDFCommentGeometry.pageNoteBounds(pageBounds: shifted, rotation: 0, slot: 0)
        XCTAssertEqual(note, CGRect(x: 28, y: 420 - 18 - 24, width: 24, height: 24))
        XCTAssertTrue(shifted.contains(note))
    }

    func testNotesPastWhatThePageHoldsShareTheLastPlaceInsteadOfLeavingThePage() {
        for rotation in [0, 90, 180, 270] {
            for slot in [0, 5, 22, 23, 24, 100, 10_000] {
                let note = PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: rotation, slot: slot)
                XCTAssertTrue(page.contains(note), "rotation \(rotation), slot \(slot): \(note)")
            }
        }
        let small = CGRect(x: 0, y: 0, width: 100, height: 60)
        XCTAssertTrue(small.contains(PDFCommentGeometry.pageNoteBounds(pageBounds: small, rotation: 0, slot: 7)))
        XCTAssertTrue(small.contains(PDFCommentGeometry.pageNoteBounds(pageBounds: small, rotation: 90, slot: 7)))
    }

    func testANegativeSlotIsTheFirst() {
        XCTAssertEqual(
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 0, slot: -3),
            PDFCommentGeometry.pageNoteBounds(pageBounds: page, rotation: 0, slot: 0)
        )
    }

    func testUnionHoldsEveryLineAndIsNilForNone() {
        let lines = [CGRect(x: 72, y: 700, width: 200, height: 14), CGRect(x: 72, y: 684, width: 90, height: 14)]
        XCTAssertEqual(PDFCommentGeometry.union(of: lines), CGRect(x: 72, y: 684, width: 200, height: 30))
        XCTAssertEqual(PDFCommentGeometry.union(of: [lines[0]]), lines[0])
        XCTAssertNil(PDFCommentGeometry.union(of: []))
    }

    func testQuadrilateralPointsAreFourPerLineRelativeToTheBoundsInReaderOrder() {
        let lines = [CGRect(x: 72, y: 700, width: 200, height: 14), CGRect(x: 72, y: 684, width: 90, height: 14)]
        let bounds = PDFCommentGeometry.union(of: lines) ?? .zero
        let points = PDFCommentGeometry.quadrilateralPoints(lineRects: lines, relativeTo: bounds)

        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(Array(points[0..<4]), [CGPoint(x: 0, y: 30), CGPoint(x: 200, y: 30), CGPoint(x: 0, y: 16), CGPoint(x: 200, y: 16)], "top line")
        XCTAssertEqual(Array(points[4..<8]), [CGPoint(x: 0, y: 14), CGPoint(x: 90, y: 14), CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0)], "bottom line")
        XCTAssertTrue(points.allSatisfy { $0.x >= 0 && $0.x <= bounds.width && $0.y >= 0 && $0.y <= bounds.height }, "inside the bounds, edges included")
        XCTAssertEqual(PDFCommentGeometry.quadrilateralPoints(lineRects: [], relativeTo: bounds), [])
    }
}
