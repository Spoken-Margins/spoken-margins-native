import SessionKit
import SwiftUI

/// Persistent information only. Retry remains on the individual Margin.
struct PlaybackMarginTranscriptionStatusView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let status: PlaybackMarginTranscriptionStatus

    var body: some View {
        if let text = status.text {
            Label {
                Text(text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: status.attentionCount > 0 ? "exclamationmark.circle" : "clock")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityLabel ?? text)
            .accessibilityIdentifier("playback.marginTranscriptionStatus")
        }
    }
}
