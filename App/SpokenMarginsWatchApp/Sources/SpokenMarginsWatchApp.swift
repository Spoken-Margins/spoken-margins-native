import SwiftUI

/// The Watch app (#2487): one large Record / Stop control for a spoken Margin, sent to the iPhone's live session.
@main
struct SpokenMarginsWatchApp: App {
    @StateObject private var recorder = WatchMarginRecorder()

    var body: some Scene {
        WindowGroup {
            WatchRecordView()
                .environmentObject(recorder)
                .task { recorder.activate() }
        }
    }
}

struct WatchRecordView: View {
    @EnvironmentObject private var recorder: WatchMarginRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                if let title = recorder.sessionTitle {
                    Text(title).font(.footnote).lineLimit(1)
                }
                Button {
                    recorder.toggle()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40, weight: .semibold))
                        Text(recorder.isRecording ? "Stop" : "Record")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Blue and orange, with the icon and word carrying the meaning too (owner is red-green colour-blind).
                .tint(recorder.isRecording ? .orange : .blue)
                .accessibilityLabel(recorder.isRecording ? "Stop and send the spoken Margin" : "Record a spoken Margin")
                statusLine(now: context.date)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func statusLine(now: Date) -> some View {
        switch recorder.state {
        case .recording(let since):
            let elapsed = Int(now.timeIntervalSince(since))
            Text([String(format: "%d:%02d", elapsed / 60, elapsed % 60), recorder.aboutPosition(at: since)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote.monospacedDigit())
        case .failed(let message):
            Text(message).font(.footnote).multilineTextAlignment(.center)
        case .idle:
            if let lastSent = recorder.lastSent {
                Text(lastSent).font(.footnote).multilineTextAlignment(.center)
            } else if let about = recorder.aboutPosition(at: now) {
                Text(about).font(.footnote.monospacedDigit())
            }
        }
    }
}
