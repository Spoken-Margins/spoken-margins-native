import SessionKit
import SwiftUI

/// The small floating "Next Margin" pill in the bottom right of whichever playback tab is showing (owner's prototype
/// v3): a double-forward icon and an m:ss countdown to the next Margin. The tab's content scrolls under it. Where it
/// goes is `NextMarginSkip`; it only moves the player when pressed, never by itself.
struct NextMarginPill: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var playbackTick = 0 // the countdown follows the playhead (#2074)

    /// Room the tabs leave at the bottom of their scrolling content so the last row can scroll clear of the pill.
    static let contentClearance: CGFloat = 60

    var body: some View {
        let _ = playbackTick
        let source = MarginsTabSource(model: model)
        Group {
            if !model.recordingNavigationIsLocked, let skip = source.nextSkip(playheadMs: model.snapshot.currentMediaTimeMs ?? 0, autoplay: model.marginsAutoplay) {
                Button { source.pressNext(skip, model: model) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.fill")
                        Text("Next Margin")
                        Text(skip.countdown)
                            .monospacedDigit()
                            .foregroundStyle(AppColors.listeningAccent)
                            .numericTextTransition()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.leading, 10)
                    .padding(.trailing, 12)
                    .frame(minHeight: 36)
                    .background(AppColors.watchControl.opacity(0.8), in: Capsule())
                    .overlay(Capsule().strokeBorder(AppColors.watchSecondary.opacity(0.24)))
                    .shadow(radius: 7, y: 4)
                    .frame(minHeight: 44) // a 44 pt target around the 36 pt pill
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip to next Margin, in \(skip.countdown)")
                .accessibilityIdentifier("playback.nextMargin.pill")
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 6)
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }
}
