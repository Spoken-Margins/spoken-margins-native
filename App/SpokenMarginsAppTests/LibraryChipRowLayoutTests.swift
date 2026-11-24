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

    // MARK: - The real chips (#4762, Test Desk FAIL on 17b235a)

    // The stand-ins above can't catch a `Menu` that measures differently from its label: on the desk both chips came out
    // about 45 pt wide and 190 to 240 pt tall at the default text size. These host the real `Menu` + `ExperienceFilterChip`
    // + `Label` in a window, the way the Library draws them, and read where each chip landed.

    private final class Frames {
        var filter: CGRect = .zero
        var sort: CGRect = .zero
    }

    private func chipFrames(width: CGFloat, size: DynamicTypeSize) async throws -> Frames {
        let frames = Frames()
        let row = LibraryChipRowLayout(spacing: 8, forcesColumn: size.isAccessibilitySize) {
            Menu {
                Button("All") {}
            } label: {
                ExperienceFilterChip(isActive: true, allowsWrapping: true) {
                    Label("Unfinished", systemImage: "line.3.horizontal.decrease.circle.fill")
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.filter = $0 }
            Menu {
                Button("Title") {}
            } label: {
                ExperienceFilterChip(isActive: false, allowsWrapping: true) {
                    Label("Recently Added", systemImage: "arrow.up.arrow.down")
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.sort = $0 }
        }
        let content = VStack(alignment: .leading) { row; Spacer(minLength: 0) }
            .padding(.horizontal, 16)
            .frame(width: width, alignment: .leading)
            .environment(\.dynamicTypeSize, size)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        // Wait for both chips to be placed and to hold still for three passes; the deadline is only a ceiling.
        var last: [CGRect] = []
        var steady = 0
        try await pollUntil(pollEvery: .milliseconds(30)) {
            window.layoutIfNeeded()
            let now = [frames.filter, frames.sort]
            steady = !now.contains(where: { $0.isEmpty }) && now == last ? steady + 1 : 0
            last = now
            return steady >= 3
        }
        XCTAssertGreaterThanOrEqual(steady, 3, "The chips never settled: filter \(frames.filter), sort \(frames.sort)")
        return frames
    }

    func testTheRealChipsShowTheirWordsSideBySideAtTheDefaultSize() async throws {
        let frames = try await chipFrames(width: 390, size: .large)
        // One line of subheadline text in a 38 pt chip with a 44 pt tap target: well under 60 pt tall.
        XCTAssertLessThan(frames.filter.height, 60, "Filter chip \(frames.filter)")
        XCTAssertLessThan(frames.sort.height, 60, "Sort chip \(frames.sort)")
        // Wide enough for a glyph and its word, not the 44 pt tap-target floor the desk saw.
        XCTAssertGreaterThan(frames.filter.width, 90, "Filter chip \(frames.filter)")
        XCTAssertGreaterThan(frames.sort.width, 110, "Sort chip \(frames.sort)")
        XCTAssertEqual(frames.filter.midY, frames.sort.midY, accuracy: 1, "a row: \(frames.filter) \(frames.sort)")
        XCTAssertLessThan(frames.filter.maxX, frames.sort.minX)
    }

    func testTheRealChipsStackWordsIntactAtAccessibilitySizes() async throws {
        let frames = try await chipFrames(width: 390, size: .accessibility3)
        XCTAssertLessThan(frames.filter.maxY, frames.sort.minY, "a column: \(frames.filter) \(frames.sort)")
        XCTAssertGreaterThan(frames.filter.width, 90, "Filter chip \(frames.filter)")
        XCTAssertGreaterThan(frames.sort.width, 110, "Sort chip \(frames.sort)")
        XCTAssertLessThanOrEqual(frames.sort.maxX, 390 - 16 + 1, "the Sort chip stays inside the column")
    }
}
