import SwiftUI
import SessionKit

/// The card on the playback screen while "Review new Margins" runs (#474): how far through the review the listener
/// is, whose Margin is coming up or playing, and the ways out. The plain "Play this moment" card
/// (`PlaybackScreen.marginMomentControl`) says "your Margins", which is wrong for a friend's.
struct ReviewNewMarginsCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    let moment: MarginMomentSequence
    @State private var playbackTick = 0 // bumped by each progress tick: the countdown follows the playhead (#2074)

    private var current: MarginMomentAnchor { moment.playing ?? moment.target }
    private var whose: String { current.label.map { "\($0)'s Margin" } ?? "A friend's Margin" }
    private var isLast: Bool { moment.unplayed.isEmpty }

    var body: some View {
        let _ = playbackTick
        VStack(alignment: .leading, spacing: 10) {
            Text("Reviewing new Margins · \(moment.reviewNumber ?? 1) of \(moment.review?.count ?? 1)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityIdentifier("review.progress")
            // A shared Margin still being placed says so (#872); it plays from its approximate time meanwhile.
            if let placing = model.sharedMarginRows.first(where: { $0.id == current.marginId })?.placementStatus.positionDescription {
                Text(placing)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityIdentifier("marginMoment.placing")
            }
            if moment.isPlayingMargin {
                Label(model.marginMomentVoiceIsPaused ? "\(whose) is paused" : "Playing \(whose)", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("review.playing")
                Button(isLast ? "Skip to the item" : "Skip to the next Margin", systemImage: "forward.end.fill", action: model.skipMarginMomentVoice)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("marginMoment.skip")
            } else {
                if let remaining = moment.msUntilTarget(currentMediaTimeMs: model.snapshot.currentMediaTimeMs) {
                    Label("\(whose) in \(Self.countdown(remaining))", systemImage: "text.bubble")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("review.comingUp")
                } else {
                    Label("Getting to \(whose)", systemImage: "text.bubble")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("review.comingUp")
                }
                if current.isApproximate {
                    Text("Approximate position: ads can differ between copies.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Button("Play it now", systemImage: "play.fill", action: model.playMarginMomentNow)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("marginMoment.playNow")
            }
            Button("Stop review", action: model.stopReviewingNewMargins)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minHeight: 44)
                .accessibilityIdentifier("marginMoment.end")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    private static func countdown(_ ms: Int) -> String {
        let seconds = max(0, Int((Double(ms) / 1000).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
