import SwiftUI
import XCTest
@testable import SpokenMarginsApp

/// #3897: an `AdaptiveStack` row never squeezes a button label into a broken word. Below the accessibility sizes it
/// is a row only when every label fits on one line each; otherwise it is a column. Each row here is rendered at the
/// default and the largest ordinary text size, 375 pt wide (the narrowest iOS 26 runs on) less 16 pt of padding on
/// each side, and its height must be exactly one line of buttons (a row) or exactly the same buttons stacked (a
/// column). A height between the two is a label wrapped inside a narrow button, which is what the share step's
/// "Return to recipient preview" beside "Open system share sheet" did. These are renderings of the container, with
/// the labels the app's rows carry, not screenshots of the screens.
@MainActor
final class AdaptiveStackFitTests: XCTestCase {
    private static let width: CGFloat = 343
    private static let spacing: CGFloat = 12
    private static let ordinarySizes: [DynamicTypeSize] = [.large, .xxxLarge]

    /// The labels the app's `AdaptiveStack` rows carry: the share step, the review step's old three-button row, and
    /// the editors' Undo/Redo rows.
    private static let rows: [(name: String, labels: [String])] = [
        ("share step", ["Return to recipient preview", "Open system share sheet"]),
        ("three buttons", ["Back to selection", "Send as a file", "Preview what your friend gets"]),
        ("undo and redo", ["Undo", "Redo", "Undo all edits"]),
        ("prepare queue", ["Prioritize", "Prepare Now", "Don't Prepare"]),
        ("preview audio", ["Preview Original", "Preview Cleaned"]),
    ]

    func testEveryRowIsOneLineOfButtonsOrTheSameButtonsStacked() {
        for size in Self.ordinarySizes {
            let oneLine = height(of: buttons(["Back"], stacked: false), size: size)
            for row in Self.rows {
                let adaptive = height(
                    of: AdaptiveStack(spacing: Self.spacing) { self.buttonViews(row.labels) },
                    size: size
                )
                let stacked = height(of: buttons(row.labels, stacked: true), size: size)
                let isRowOfOneLines = abs(adaptive - oneLine) <= 2
                let isColumn = abs(adaptive - stacked) <= 2
                XCTAssertTrue(
                    isRowOfOneLines || isColumn,
                    "\(size), \(row.name): the row is \(adaptive) pt high; one line of buttons is \(oneLine) pt and the buttons stacked are \(stacked) pt, so a label wrapped inside a narrow button"
                )
            }
        }
    }

    func testLongLabelsBecomeAColumnAndShortOnesStayARow() {
        for size in Self.ordinarySizes {
            let oneLine = height(of: buttons(["Back"], stacked: false), size: size)
            let longLabels = ["Return to recipient preview", "Open system share sheet"]
            let long = height(of: AdaptiveStack(spacing: Self.spacing) { self.buttonViews(longLabels) }, size: size)
            XCTAssertGreaterThan(long, oneLine * 1.5, "\(size): two long labels still share one row")

            let shortLabels = ["Undo", "Redo"]
            let short = height(of: AdaptiveStack(spacing: Self.spacing) { self.buttonViews(shortLabels) }, size: size)
            XCTAssertEqual(short, oneLine, accuracy: 2, "\(size): two short labels were stacked, so a row that fits changed shape")
        }
    }

    /// An `AdaptiveSpacer` in a column draws nothing, whether the column came from the text size or from labels that
    /// did not fit, so the column is no taller than the buttons and the gaps between them.
    func testASpacerAddsNoHeightWhenTheRowBecomesAColumn() {
        for size in Self.ordinarySizes {
            let labels = ["Return to recipient preview", "Open system share sheet"]
            let withSpacer = height(
                of: AdaptiveStack(spacing: Self.spacing) {
                    Button(labels[0]) {}.buttonStyle(.bordered)
                    AdaptiveSpacer()
                    Button(labels[1]) {}.buttonStyle(.bordered)
                },
                size: size
            )
            let without = height(of: buttons(labels, stacked: true, withIcons: false), size: size)
            XCTAssertEqual(withSpacer, without, accuracy: 2, "\(size): the spacer added height to the column")
        }
    }

    // MARK: - Rendering

    @ViewBuilder
    private func buttonViews(_ labels: [String]) -> some View {
        ForEach(labels, id: \.self) { label in
            Button(label, systemImage: "arrow.left") {}.buttonStyle(.bordered)
        }
    }

    private func buttons(_ labels: [String], stacked: Bool, withIcons: Bool = true) -> some View {
        let content = ForEach(labels, id: \.self) { label in
            Button {
            } label: {
                if withIcons { Label(label, systemImage: "arrow.left") } else { Text(label) }
            }
            .buttonStyle(.bordered)
        }
        return Group {
            if stacked {
                VStack(alignment: .leading, spacing: Self.spacing) { content }
            } else {
                HStack(spacing: Self.spacing) { content }
            }
        }
    }

    private func height(of view: some View, size: DynamicTypeSize) -> CGFloat {
        let renderer = ImageRenderer(content: view.environment(\.dynamicTypeSize, size))
        renderer.proposedSize = ProposedViewSize(width: Self.width, height: nil)
        renderer.scale = 2
        return renderer.uiImage?.size.height ?? 0
    }
}
