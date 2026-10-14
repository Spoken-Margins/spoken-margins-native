import SessionKit
import SwiftUI

struct PlaybackSleepTagView: View {
    let state: SleepTimerState
    let remainingSeconds: Int?

    var body: some View {
        if let title = PlaybackSourceLabels.sleepTag(state: state, remainingSeconds: remainingSeconds) {
            Label(title, systemImage: "moon.zzz")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(AppColors.watchSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("playback.sleepTimer.tag")
        }
    }
}

#Preview("Active and deferred sleep") {
    VStack(alignment: .leading) {
        PlaybackSleepTagView(state: .armed(mode: .minutes15, deadline: nil, chapterId: nil), remainingSeconds: 720)
        PlaybackSleepTagView(state: .expiryDeferred(mode: .minutes15), remainingSeconds: 0)
    }
    .padding()
    .background(AppColors.listeningBackground)
}
