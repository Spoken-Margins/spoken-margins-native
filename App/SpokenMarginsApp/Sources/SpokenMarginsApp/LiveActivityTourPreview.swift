#if DEBUG
import SwiftUI

/// The Live Activity's Lock Screen card, shown in place of the app for the screen tour (#1940).
///
/// A UI test can't lock the simulator to photograph the real Lock Screen, so this lays out the real card,
/// `Gate2LiveActivityView`, at the narrowest Lock Screen width and the text size the launch asks for, and prints
/// its measured size under it. The paused card with a next chapter is the tallest; the playing one follows.
/// A card wider than the dashed outline would cut a control off on a 375 pt phone.
struct LiveActivityTourPreview: View {
    /// The Live Activity's width on a 375 pt-wide phone, the narrowest iOS 26 runs on (LiveActivityLayoutTests).
    static let cardWidth: CGFloat = 343
    /// The system may cut off a Lock Screen Live Activity taller than this.
    static let heightLimit: CGFloat = 160

    let textSize: DynamicTypeSize

    /// The text size named by a launch, or nil when the name matches no `DynamicTypeSize` case.
    init?(textSizeName: String) {
        guard let size = DynamicTypeSize.allCases.first(where: { String(describing: $0) == textSizeName }) else {
            return nil
        }
        textSize = size
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Live Activity, text size \(textSize)")
                    .font(.headline)
                    .accessibilityIdentifier("liveActivityPreview.screen")
                ForEach(["paused", "playing"], id: \.self) { status in
                    MeasuredCard(state: Self.state(status: status), textSize: textSize)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    /// The same long title and chapters as LiveActivityLayoutTests, so the screenshot shows the case it measures.
    static func state(status: String) -> Gate2LiveActivityAttributes.ContentState {
        Gate2LiveActivityAttributes.ContentState(
            title: "The Long Title of an Episode That Runs Past One Line",
            chapterTitle: "Chapter 4: A Chapter Title Long Enough to Need Shrinking",
            nextChapterTitle: "Chapter 5: What Comes Next",
            nextChapterId: "chapter-5",
            nextNavigationKind: .sourceChapter,
            status: status,
            phase: "itemPlayback",
            progressPercent: 42,
            isRecording: false,
            availableCommands: [
                "skimBackward", "skipBack", "togglePlayPause", "skipForward", "skimForward", "beginInterjection",
            ],
            skimForwardDestinationMs: 3_725_000,
            skimBackwardDestinationMs: 3_605_000
        )
    }
}

private struct MeasuredCard: View {
    let state: Gate2LiveActivityAttributes.ContentState
    let textSize: DynamicTypeSize
    @State private var size: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Gate2LiveActivityView(state: state, isStale: false)
                .environment(\.dynamicTypeSize, textSize)
                .fixedSize(horizontal: false, vertical: true)
                // Measured and filled before the frame, so a card wider than the Lock Screen shows past the outline.
                .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: .rect(cornerRadius: 22))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .frame(width: LiveActivityTourPreview.cardWidth, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    // The space the Lock Screen gives the card: 343 pt wide, 160 pt tall.
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: LiveActivityTourPreview.cardWidth, height: LiveActivityTourPreview.heightLimit)
                        .allowsHitTesting(false)
                }
            Text(verbatim: "\(state.status): \(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt "
                + "(limit \(Int(LiveActivityTourPreview.cardWidth)) × \(Int(LiveActivityTourPreview.heightLimit)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityIdentifier("liveActivityPreview.size.\(state.status)")
        }
    }
}
#endif
