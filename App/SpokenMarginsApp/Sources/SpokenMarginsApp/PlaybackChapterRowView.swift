import SwiftUI

struct PlaybackChapterRowView: View {
    let title: String?
    let canJumpToNextChapter: Bool
    let showItem: () -> Void
    let nextChapter: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: showItem) {
                Text(title ?? "Current source")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("playback.dock.chapter.button")
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
