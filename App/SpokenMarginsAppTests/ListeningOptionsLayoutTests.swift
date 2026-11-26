import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// #5333: at the largest text size Listening options lost the leading words of every row ("ote audio", "ong pauses
/// are"). One row was wider than the sheet, and a vertical `ScrollView` centres content that is wider than itself, so the
/// whole column slid off the leading edge. These host the real column and the real bottom row (Details, Timeline,
/// Export) in a phone-width window, with a wrapping caption standing in for the Note audio panel's text, and read where
/// each landed.
@MainActor
final class ListeningOptionsLayoutTests: XCTestCase {
    /// iPhone 17 (the desk's simulator) and iPhone SE widths.
    private static let widths: [CGFloat] = [402, 375]
    private static let caption = "Long pauses are shortened. Your recording stays as it is."

    private final class Frames {
        var dock: CGRect = .zero
        var caption: CGRect = .zero
    }

    /// Mounts `ListeningOptionsColumn` holding `extraRow` (if any), the caption and the dock, and waits until both
    /// frames are placed and hold still for three passes; the deadline is only a ceiling.
    private func frames(
        width: CGFloat,
        size: DynamicTypeSize,
        extraRowWidth: CGFloat? = nil
    ) async throws -> Frames {
        let frames = Frames()
        let content = ListeningOptionsColumn {
            if let extraRowWidth {
                Color.clear.frame(width: extraRowWidth, height: 10)
            }
            Text(Self.caption)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.caption = $0 }
            ListeningOptionsActionDock(exportDisabled: false, showDetails: {}, showTimeline: {}, showExport: {})
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.dock = $0 }
        }
        .environment(\.dynamicTypeSize, size)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_600)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        var last: [CGRect] = []
        var steady = 0
        try await pollUntil(pollEvery: .milliseconds(30)) {
            window.layoutIfNeeded()
            let now = [frames.dock, frames.caption]
            steady = !now.contains(where: { $0.isEmpty }) && now == last ? steady + 1 : 0
            last = now
            return steady >= 3
        }
        XCTAssertGreaterThanOrEqual(steady, 3, "Never settled: dock \(frames.dock), caption \(frames.caption)")
        return frames
    }

    private func assertInside(_ frame: CGRect, width: CGFloat, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let margin = ListeningOptionsColumn<EmptyView>.margin
        XCTAssertGreaterThanOrEqual(frame.minX, margin - 1, "\(what) starts left of the column at width \(width): \(frame)",
                                    file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, width - margin + 1, "\(what) ends right of the column at width \(width): \(frame)",
                                 file: file, line: line)
    }

    /// The desk's failure: at AX5 the bottom row pushed the column wider than the phone. Both rows stay inside it.
    func testEveryRowStaysInsideTheSheetAtTheLargestTextSize() async throws {
        for width in Self.widths {
            let frames = try await frames(width: width, size: .accessibility5)
            assertInside(frames.dock, width: width, "The Details, Timeline and Export row")
            assertInside(frames.caption, width: width, "The caption")
        }
    }

    /// At the default size the bottom row is still one row of 48-point buttons.
    func testTheBottomRowIsOneRowAtTheDefaultSize() async throws {
        for width in Self.widths {
            let frames = try await frames(width: width, size: .large)
            assertInside(frames.dock, width: width, "The Details, Timeline and Export row")
            XCTAssertLessThan(frames.dock.height, 80, "one row of 48 pt buttons plus 8 pt padding: \(frames.dock)")
        }
    }

    /// A future row that is too wide must not take the other rows with it: they keep the column's leading edge.
    func testATooWideRowDoesNotPushTheOtherRowsOffTheLeadingEdge() async throws {
        let width: CGFloat = 402
        let frames = try await frames(width: width, size: .large, extraRowWidth: width * 1.5)
        assertInside(frames.caption, width: width, "The caption beside a too-wide row")
    }
}
