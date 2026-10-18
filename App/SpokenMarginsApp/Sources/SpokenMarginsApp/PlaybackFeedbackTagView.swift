import SessionKit
import SwiftUI

/// A summary or transcription failure about what's playing, as one orange line at the top of the playback
/// screen instead of a banner over the title (#430). The icon's shape tells an error (octagon) from a
/// warning (triangle), so orange carries no meaning alone. Retry keeps its name, and the full message
/// stays on the item.
struct PlaybackFeedbackTagView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: UserFeedbackEvent
    let tag: PlaybackFeedbackTag

    var body: some View {
        HStack(spacing: 4) {
            Label {
                Text(tag.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: tag.isFailure ? "xmark.octagon" : "exclamationmark.triangle")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playback.feedbackTag")

            if tag.offersRetry, let retry = event.retry {
                Text("·")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Button {
                    model.dismissFeedback(id: event.id)
                    retry.action()
                } label: {
                    Text("Retry")
                        .font(.caption.weight(.semibold))
                        .underline()
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("playback.feedbackTag.retry")
            }

            Spacer(minLength: 0)

            if tag.isFailure {
                Button {
                    model.dismissFeedback(id: event.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.watchSecondary)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("playback.feedbackTag.dismiss")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}
