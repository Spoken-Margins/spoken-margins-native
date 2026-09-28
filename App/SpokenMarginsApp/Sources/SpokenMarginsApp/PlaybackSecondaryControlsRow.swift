import SwiftUI

/// The rate, Sleep and More row under the player's transport. Each item keeps its ideal width on
/// one line: the row is offered less width than it needs, and at 2.00× the wider rate text made
/// "Sleep" wrap mid-word ("Sle" / "ep", #221 lane).
struct PlaybackSecondaryControlsRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 24) {
            content
        }
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
