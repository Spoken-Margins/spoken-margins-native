import SessionKit
import SwiftUI

/// Preparation belongs with listening options, separate from the source-position scrubber.
struct PlaybackPreparedAudioView: View {
    let fraction: Double?
    let isNativeAudio: Bool

    var body: some View {
        if let title = PlaybackSourceLabels.preparedAudio(fraction: fraction, isNativeAudio: isNativeAudio),
           let fraction {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.medium))
                ProgressView(value: max(0, min(1, fraction)))
                    .tint(AppColors.accent)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AppColors.watchSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playback.preparedProgress.status")
        }
    }
}

#Preview("Partly prepared text") {
    PlaybackPreparedAudioView(fraction: 0.65, isNativeAudio: false)
        .padding()
        .background(AppColors.listeningBackground)
}
