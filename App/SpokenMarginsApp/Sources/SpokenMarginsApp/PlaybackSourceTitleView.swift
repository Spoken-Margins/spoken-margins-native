import SessionKit
import SwiftUI

struct PlaybackSourceTitleView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    /// `.compact` while a friend's Margin card holds its slot: one small line, so the title never crowds the card (#3598).
    var mode: PlaybackTitleMode = .full
    /// The show or source name, for the compact line; the title itself when nil.
    var sourceName: String?
    let sleepTimerState: SleepTimerState
    let sleepTimerRemainingSeconds: Int?
    let showItem: () -> Void

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            Button(action: showItem) {
                switch mode {
                case .full:
                    PlaybackHeaderTitle(title: title)
                        .foregroundStyle(.white)
                case .compact:
                    Text(PlaybackTitleMode.compactLine(title: title, sourceName: sourceName))
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(AppColors.watchSecondary)
                        .accessibilityLabel(title) // VoiceOver still reads the full title
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHint("Opens details and listening-session history")
            .accessibilityInputLabels(mode.voiceControlNames(title: title, sourceName: sourceName).map { Text($0) })
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

#Preview("Margin card up") {
    PlaybackSourceTitleView(title: "An article with a longer title", mode: .compact, sourceName: "The Show", sleepTimerState: .inactive, sleepTimerRemainingSeconds: nil, showItem: {})
        .padding()
        .background(AppColors.listeningBackground)
}
