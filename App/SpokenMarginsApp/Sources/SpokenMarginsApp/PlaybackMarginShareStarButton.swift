import SwiftUI
// Named Playback* because it draws with AppColors.watch*, which only the always-dark playback files may use (ExperienceColorContrastTests).
import SessionKit

/// The sharing star on one of the listener's own Margin rows while they listen (#4173). One tap fills it, a second clears
/// it. It only selects: the Share Margins sheet starts from the stars, and nothing is sent until a Share button is tapped.
/// The filled or outline shape carries the state, so the amber never does it alone.
struct MarginShareStarButton: View {
    let isStarred: Bool
    /// The words of the row, for VoiceOver. Cut to `Self.spokenTitleLimit` characters.
    let title: String
    let identifier: String
    let action: () -> Void

    static let spokenTitleLimit = 60

    /// "Star for sharing: <first 60 characters of the row's words>".
    static func accessibilityLabel(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Star for sharing: \(String(trimmed.prefix(spokenTitleLimit)))"
    }

    static func accessibilityValue(isStarred: Bool) -> String { isStarred ? "Starred" : "Not starred" }

    var body: some View {
        Button(action: action) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? AppColors.watchStar : AppColors.watchSecondary)
                .minimumTapTarget()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isStarred)
        .accessibilityLabel(Self.accessibilityLabel(title: title))
        .accessibilityValue(Self.accessibilityValue(isStarred: isStarred))
        .accessibilityHint("Starred Margins start selected when you share.")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(identifier)
    }
}

extension PlaybackMarginRowView.Star {
    /// The star for the listener's own Margin row, or nil for a Margin Share can't send (#4173).
    @MainActor
    static func ownMargin(_ interjection: Interjection, place: ShareStarPlace, model: Gate1AppModel) -> PlaybackMarginRowView.Star? {
        guard interjection.isOfferedShareStar else { return nil }
        return PlaybackMarginRowView.Star(isStarred: interjection.isStarredForSharing == true) {
            model.toggleStarredForSharing(interjection, place: place)
        }
    }
}
