import SwiftUI

struct ExperienceRecordingView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppColors.coral, Color(red: 0.42, green: 0.10, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 9) {
                    Label("RECORDING", systemImage: "record.circle.fill")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                    Text("Your margin")
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                }
                .foregroundStyle(.white)
                .accessibilityIdentifier("recording.screen")

                TimelineView(.periodic(from: context.startedAt, by: 1)) { timeline in
                    VStack(spacing: 18) {
                        RecordingWaveform(
                            phase: reduceMotion ? 0 : timeline.date.timeIntervalSince(context.startedAt)
                        )
                        Text(elapsedDescription(at: timeline.date))
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)
                            .accessibilityLabel("Recording duration \(elapsedDescription(at: timeline.date))")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("Anchor locked", systemImage: "lock.fill")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                    Text(context.itemTitle)
                        .font(.title3.weight(.semibold))
                    Text("\(context.locationTitle) · \(context.progressPercent)%")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                }
                .foregroundStyle(.white)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.18)) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording anchor. \(context.itemTitle), \(context.locationTitle), \(context.progressPercent) percent")
                .accessibilityIdentifier("recording.anchor")

                if let error = model.lastError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(AppColors.coral.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("Finish saves this Margin, returns to the locked point, and resumes listening. Cancel discards only this recording.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                Spacer()
                VStack(spacing: 12) {
                    Button(action: model.finishInterjection) {
                        Label("Finish", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(AppColors.interjectText)
                    .accessibilityIdentifier("recording.finish.button")
                    Button(role: .destructive, action: model.cancelInterjection) {
                        Label("Cancel", systemImage: "xmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.9))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("recording.cancel.button")
                }
                .padding(.bottom, 20)
            }
            .padding(24)
            .frame(maxWidth: 560)
        }
        .accessibilityAction(.escape, model.cancelInterjection)
    }

    private var context: RecordingPresentationContext {
        model.recordingPresentationContext ?? RecordingPresentationContext(
            itemTitle: model.selectedItem.title.isEmpty ? "Current item" : model.selectedItem.title,
            locationTitle: model.snapshot.chapterTitle ?? "Current listening position",
            progressPercent: model.snapshot.currentPlaybackProgressPercent,
            startedAt: Date()
        )
    }

    private func elapsedDescription(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(context.startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RecordingWaveform: View {
    let phase: TimeInterval

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(0..<25, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index.isMultiple(of: 3) ? 1 : 0.68))
                    .frame(width: 4, height: barHeight(index))
            }
        }
        .frame(height: 72)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let value = sin((Double(index) * 0.72) + phase * 2.1)
        return 18 + CGFloat(abs(value)) * 48
    }
}

