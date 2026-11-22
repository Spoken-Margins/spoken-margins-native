import SwiftUI
import SessionKit

/// A detail target and a separate, full-size play target. Both stay available to VoiceOver.
struct PlaybackMarginRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let detail: String
    var countdown: String? = nil
    let isShared: Bool
    let identifier: String
    var canPlay = true
    var playLabel = "Play this moment"
    var playHint: String? = nil
    /// A live session's photo beside the words (#2708); its Margin's row also reads "with a photo".
    var thumbnail: AnyView? = nil
    /// The sharing star (#4173). Only the listener's own rows pass it; a friend's row and a live session's row pass nil
    /// and look as before.
    var star: Star? = nil
    let showDetails: () -> Void
    let play: () -> Void

    struct Star {
        let isStarred: Bool
        let action: () -> Void
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize && star != nil {
                // A row with a star: the words take the full width; the star and Play sit under them, as the detail sheet's actions do.
                VStack(alignment: .leading, spacing: 8) {
                    detailsButton
                    HStack(spacing: 12) {
                        starButton
                        playButton
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    detailsButton
                    starButton
                    playButton
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
    }

    private var label: String {
        if isShared { return "Shared Margin" }
        return star?.isStarred == true ? "My Margin · Starred" : "My Margin"
    }

    @ViewBuilder
    private var starButton: some View {
        if let star {
            MarginShareStarButton(isStarred: star.isStarred, title: title, identifier: "\(identifier).star", action: star.action)
        }
    }

    private var detailsButton: some View {
        Button(action: showDetails) {
            HStack(alignment: .top, spacing: 10) {
                if let thumbnail { thumbnail }
                VStack(alignment: .leading, spacing: 6) {
                    Label(label, systemImage: isShared ? "person.2" : "quote.bubble")
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
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .modifier(OptionalAccessibilityValue(value: thumbnail == nil ? nil : LiveSessionPhotoMargin.rowAccessibilityValue))
        .accessibilityIdentifier(identifier)
    }

    private var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .minimumTapTarget()
        }
        .disabled(!canPlay)
        .accessibilityLabel("\(playLabel): \(title)")
        .accessibilityHint(playHint ?? (canPlay ? "Plays the source lead-in and this Margin" : "Open details to review this Margin’s audio and position"))
        .accessibilityIdentifier("\(identifier).play")
    }
}

/// Adds an accessibility value only when there is one, so a row without a photo is read exactly as before.
private struct OptionalAccessibilityValue: ViewModifier {
    let value: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value { content.accessibilityValue(value) } else { content }
    }
}

/// Whether the Play button on a friend's Margin row is enabled (#3425). Asked of `SharedMarginAudio`, so a written
/// Margin (no recording, a reading) is offered as a voice Margin is; the views and the app tests share these.
extension SharedMarginRow {
    /// The Now tab's "Nearby Margins" row.
    var canPlayFromNearbyList: Bool { SharedMarginAudio.canOffer(interjection) }
    /// The Margins tab's row also needs a place to jump to: a time in the episode, or a matched passage of the text
    /// in a layer that is on (`SharedMarginListPlay`, #4447).
    var canPlayFromMarginsList: Bool { SharedMarginListPlay.canPlay(interjection, in: layer) }
}
