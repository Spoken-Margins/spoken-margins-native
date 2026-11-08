import SwiftUI
import SessionKit

/// A detail target and a separate, full-size play target. Both stay available to VoiceOver.
struct PlaybackMarginRowView: View {
    let title: String
    let detail: String
    var countdown: String? = nil
    let isShared: Bool
    let identifier: String
    var canPlay = true
    var playLabel = "Play this moment"
    var playHint: String? = nil
    let showDetails: () -> Void
    let play: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(isShared ? "Shared Margin" : "My Margin", systemImage: isShared ? "person.2" : "quote.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.watchSecondary)
                    Text(title)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppColors.watchSecondary)
                    if let countdown {
                        Text(countdown)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppColors.listeningAccent)
                            .numericTextTransition()
                            .accessibilityIdentifier("\(identifier).countdown")
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier(identifier)
            Button(action: play) {
                Image(systemName: "play.fill")
                    .minimumTapTarget()
            }
            .disabled(!canPlay)
            .accessibilityLabel("\(playLabel): \(title)")
            .accessibilityHint(playHint ?? (canPlay ? "Plays the source lead-in and this Margin" : "Open details to review this Margin’s audio and position"))
            .accessibilityIdentifier("\(identifier).play")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
    }
}

/// Whether the Play button on a friend's Margin row is enabled (#3425). Asked of `SharedMarginAudio`, so a written
/// Margin (no recording, a reading) is offered as a voice Margin is; the views and the app tests share these.
extension SharedMarginRow {
    /// The Now tab's "Nearby Margins" row.
    var canPlayFromNearbyList: Bool { SharedMarginAudio.canOffer(interjection) }
    /// The Margins tab's row also needs a place in the episode to jump to.
    var canPlayFromMarginsList: Bool { canPlayFromNearbyList && SharedMarginPlaybackPosition(interjection) != nil }
}
