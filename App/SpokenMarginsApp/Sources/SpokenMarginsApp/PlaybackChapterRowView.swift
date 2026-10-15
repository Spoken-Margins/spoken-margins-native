import SwiftUI
import SessionKit

struct PlaybackChapterRowView: View {
    let title: String?
    let sourceTitle: String
    let canJumpToNextChapter: Bool
    /// What the silence is while playback starts. It takes the title's place in this fixed-height row, so the
    /// dock never changes height while the listener scrubs or starts a source (#357, #430).
    var waitingText: String?
    let showItem: () -> Void
    let nextChapter: () -> Void

    var body: some View {
        HStack(spacing: 8) {
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
            if canJumpToNextChapter {
                Button(action: nextChapter) {
                    Image(systemName: "forward.end")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Next chapter")
                .accessibilityIdentifier("playback.nextChapter.button")
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }
}
