import SwiftUI

/// Feed choices are shared with Following and can predate the currently playing source.
struct PlaybackFollowOptionsView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        ManualSourceFollowButton()
        if !model.followedSourceCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pending feed choices")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.watchSecondary)
                FollowCandidateChoices()
            }
        }
    }
}
