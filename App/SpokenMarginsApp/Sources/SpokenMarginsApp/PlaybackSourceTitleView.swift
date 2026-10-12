import SessionKit
import SwiftUI

struct PlaybackSourceTitleView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let sleepTimerState: SleepTimerState
    let sleepTimerRemainingSeconds: Int?
    let showItem: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Button(action: showItem) {
                PlaybackHeaderTitle(title: title)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint("Opens item details and listening-session history")
            .accessibilityIdentifier("playback.itemTitle.button")

            PlaybackSleepTagView(state: sleepTimerState, remainingSeconds: sleepTimerRemainingSeconds)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        }
    }
}

#Preview("Source with active sleep") {
    PlaybackSourceTitleView(title: "An article with a longer title", sleepTimerState: .armed(mode: .minutes15, deadline: nil, chapterId: nil), sleepTimerRemainingSeconds: 720, showItem: {})
        .padding()
        .background(AppColors.listeningBackground)
}

#Preview("Large text") {
    PlaybackSourceTitleView(title: "An article with a longer title", sleepTimerState: .expiryDeferred(mode: .minutes15), sleepTimerRemainingSeconds: 0, showItem: {})
        .environment(\.dynamicTypeSize, .accessibility3)
        .padding()
        .background(AppColors.listeningBackground)
}
