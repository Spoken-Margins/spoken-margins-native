import SwiftUI
import SessionKit

struct PlaybackChapterRowView: View {
    let title: String?
    let sourceTitle: String
    /// Left and right of the title (#1666). Skim sits here, not under the transport, and keeps its place when the
    /// listener crosses a chapter: the right side is Skim forward, else Next chapter, else a dimmed Skim.
    var backward: NextChapterSummaryRule.ChapterRowControl = .hidden
    var forward: NextChapterSummaryRule.ChapterRowControl = .hidden
    var skimBackwardTitle = ""
    var skimForwardTitle = ""
    /// What the silence is while playback starts. It takes the title's place in this fixed-height row, so the
    /// dock never changes height while the listener scrubs or starts a source (#357, #430).
    var waitingText: String?
    let showItem: () -> Void
    let nextChapter: () -> Void
    var skimBackward: () -> Void = {}
    var skimForward: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if backward != .hidden {
                skimButton(backward: true, enabled: backward == .skim)
            }
            if let waitingText {
                Text(waitingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.watchSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("playback.starting.label")
            } else {
                Button(action: showItem) {
                    Text(PlaybackSourceLabels.chapterTitle(title, sourceTitle: sourceTitle))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("playback.dock.chapter.button")
            }
            switch forward {
            case .skim, .skimDisabled:
                skimButton(backward: false, enabled: forward == .skim)
            case .nextChapter:
                Button(action: nextChapter) {
                    Image(systemName: "forward.end")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next chapter")
                .accessibilityIdentifier("playback.nextChapter.button")
            case .hidden:
                EmptyView()
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// A compact Skim arrow. It says where it goes ("Skim to 36:11") for VoiceOver; a dimmed one reads as unavailable.
    private func skimButton(backward isBackward: Bool, enabled: Bool) -> some View {
        Button(action: isBackward ? skimBackward : skimForward) {
            Image(systemName: isBackward ? "backward.end.alt.fill" : "forward.end.alt.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel((isBackward ? skimBackwardTitle : skimForwardTitle) + " by scene summary")
        .accessibilityIdentifier(isBackward ? "playback.skim.backward.button" : "playback.skim.forward.button")
    }
}
