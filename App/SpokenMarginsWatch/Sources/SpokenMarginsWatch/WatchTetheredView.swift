import SessionKit
import SwiftUI

struct WatchTetheredView: View {
    @EnvironmentObject private var model: WatchTetheredModel
    @Environment(\.scenePhase) private var scenePhase
    private let sideTransportSize: CGFloat = 42
    private let playButtonSize: CGFloat = 54

    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                header
                transportControls
                if model.isRecording {
                    recordingControls
                } else {
                    actionControls
                }
                discussControl
                timelineSection
                footer
            }
            .padding(.horizontal, 8)
            .padding(.top, 30)
            .padding(.bottom, 12)
        }
        .ignoresSafeArea(edges: .top)
        .containerBackground(.black, for: .navigation)
        .onAppear {
            model.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refresh()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text(model.targetLabel.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(model.chapterTitle)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.64)
            Text(model.progressText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            progressRail
        }
    }

    private var transportControls: some View {
        HStack(alignment: .center, spacing: 10) {
            iconButton(
                systemName: "chevron.backward",
                label: "Skip back",
                size: sideTransportSize,
                symbolSize: 21,
                prominent: false,
                enabled: model.canSend(.skipBack),
                action: model.skipBackChapter
            )
            iconButton(
                systemName: model.isPlaying ? "pause.fill" : "play.fill",
                label: model.isPlaying ? "Pause" : "Play",
                size: playButtonSize,
                symbolSize: 25,
                prominent: true,
                enabled: model.canSend(.togglePlayPause)
            ) {
                model.send(.togglePlayPause)
            }
            iconButton(
                systemName: "chevron.forward",
                label: "Skip forward",
                size: sideTransportSize,
                symbolSize: 21,
                prominent: false,
                enabled: model.canSend(.skipForward),
                action: model.skipForwardChapter
            )
        }
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            actionPill(
                systemName: "sparkles",
                title: "Summary",
                enabled: model.canSend(.generateInterjectionSummary)
            ) {
                model.send(.generateInterjectionSummary)
            }
            actionPill(
                systemName: "mic.fill",
                title: "Interject",
                enabled: model.canSend(.beginInterjection)
            ) {
                model.send(.beginInterjection)
            }
        }
    }

    private var progressRail: some View {
        GeometryReader { proxy in
            let progress = min(max(CGFloat(model.snapshot?.sourceProgressPercent ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.12))
                Capsule()
                    .fill(.green.opacity(0.82))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
    }

    private var recordingControls: some View {
        VStack(spacing: 6) {
            Label("Recording", systemImage: "record.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            HStack(spacing: 8) {
                actionPill(systemName: "checkmark", title: "Finish", enabled: model.canSend(.finishInterjection), prominent: true) {
                    model.send(.finishInterjection)
                }
                actionPill(systemName: "xmark", title: "Cancel", enabled: model.canSend(.cancelInterjection), prominent: false) {
                    model.send(.cancelInterjection)
                }
            }
        }
    }

    private var discussControl: some View {
        Group {
            Button {
                model.discuss()
            } label: {
                Label("Discuss", systemImage: "text.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .disabled(!model.canSend(.submitFollowup))
            .opacity(model.canSend(.submitFollowup) ? 1 : 0.45)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if model.hasTimeline {
                ForEach(model.timeline) { entry in
                    timelineRow(entry)
                }
            } else {
                Text("Open the phone app to sync chapters.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
            } else {
                Text(model.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private func iconButton(
        systemName: String,
        label: String,
        size: CGFloat,
        symbolSize: CGFloat,
        prominent: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .semibold))
                .frame(width: size, height: size)
                .background(prominent ? .white.opacity(0.36) : .white.opacity(0.13), in: Circle())
                .overlay(Circle().stroke(.white.opacity(prominent ? 0.16 : 0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func actionPill(
        systemName: String,
        title: String,
        enabled: Bool,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(prominent ? .white.opacity(0.22) : .white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func timelineRow(_ entry: CompactTimelineEntry) -> some View {
        let canJump = entry.kind == "source_chapter" && entry.chapterId != nil && model.canSend(.jumpToChapter)
        if canJump, let chapterId = entry.chapterId {
            Button {
                model.jumpToChapter(chapterId)
            } label: {
                timelineRowContent(entry)
            }
            .buttonStyle(.plain)
        } else {
            timelineRowContent(entry)
        }
    }

    private func timelineRowContent(_ entry: CompactTimelineEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: entry))
                .font(.caption2.weight(.bold))
                .frame(width: 14)
                .foregroundStyle(entry.isCurrent ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.caption2.weight(entry.isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                HStack(spacing: 4) {
                    if let detail = entry.detail {
                        Text(detail)
                    }
                    if let percent = entry.percent {
                        Text("\(percent)%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(entry.isCurrent ? .green.opacity(0.18) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func iconName(for entry: CompactTimelineEntry) -> String {
        switch entry.kind {
        case "overview":
            return "sparkles"
        case "source_item":
            return "play.circle.fill"
        case "source_chapter":
            return "list.bullet"
        case "interjection":
            return "mic.fill"
        case "interjection_summary":
            return "sparkles"
        case "assistant_response":
            return "bubble.left.and.bubble.right.fill"
        case "user_response":
            return "text.bubble.fill"
        case "turn_chapter":
            return "text.line.first.and.arrowtriangle.forward"
        default:
            return "circle"
        }
    }
}
