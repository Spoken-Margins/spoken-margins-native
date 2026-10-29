import SwiftUI

/// A detail target and a separate, full-size play target. Both stay available to VoiceOver.
struct PlaybackMarginRowView: View {
    let title: String
    let detail: String
    var countdown: String? = nil
    let isShared: Bool
    let identifier: String
    var canPlay = true
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
            .accessibilityLabel("Play this moment: \(title)")
            .accessibilityHint(canPlay ? "Plays the source lead-in and this Margin" : "Open details to review this Margin’s audio and position")
            .accessibilityIdentifier("\(identifier).play")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
    }
}
