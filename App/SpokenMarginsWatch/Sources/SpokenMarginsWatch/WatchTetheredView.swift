import SessionKit
import SwiftUI

struct WatchTetheredView: View {
    @EnvironmentObject private var model: WatchTetheredModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                transportControls
                if model.isRecording {
                    recordingControls
                } else {
                    actionControls
                }
                footer
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .containerBackground(.black, for: .navigation)
        .onAppear {
            model.refresh()
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text(model.targetLabel.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(model.chapterTitle)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
            Text(model.progressText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                model.skipBackChapter()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.skipBack))

            Button {
                model.send(.togglePlayPause)
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSend(.togglePlayPause))

            Button {
                model.skipForwardChapter()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.skipForward))
        }
        .font(.title3)
    }

    private var recordingControls: some View {
        VStack(spacing: 8) {
            Label("Recording", systemImage: "record.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            HStack {
                Button {
                    model.send(.finishInterjection)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend(.finishInterjection))

                Button {
                    model.send(.cancelInterjection)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canSend(.cancelInterjection))
            }
        }
    }

    private var actionControls: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    model.send(.generateInterjectionSummary)
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(!model.canSend(.generateInterjectionSummary))

                Button {
                    model.send(.beginInterjection)
                } label: {
                    Label("Interject", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend(.beginInterjection))
            }

            Button {
                model.discuss()
            } label: {
                Label("Discuss", systemImage: "text.bubble.fill")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canSend(.submitFollowup))
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text(model.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .minimumScaleFactor(0.65)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
    }
}
