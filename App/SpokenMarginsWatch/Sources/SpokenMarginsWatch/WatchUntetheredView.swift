import SessionKit
import SwiftUI

struct WatchUntetheredView: View {
    @EnvironmentObject private var library: WatchOfflineLibraryModel
    @EnvironmentObject private var playback: WatchLocalPlaybackModel
    @EnvironmentObject private var connectivity: WatchConnectivityInbox
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if playback.activePackage == nil {
                itemsScreen
            } else {
                playbackScreen
            }
        }
        .containerBackground(.black, for: .navigation)
        .onAppear {
            library.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, playback.activePackage == nil else { return }
            library.refresh()
        }
    }

    private var itemsScreen: some View {
        List {
            Section {
                if library.packageRows.isEmpty {
                    Text("Open iPhone to sync items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(library.packageRows.enumerated()), id: \.offset) { _, row in
                        Button {
                            library.selectPackageRow(row, playback: playback)
                        } label: {
                            rowContent(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Items")
                    Spacer(minLength: 4)
                    Button {
                        library.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh")
                }
            }

            if let error = library.lastError ?? playback.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .minimumScaleFactor(0.68)
            } else {
                Text(connectivity.isReachable ? connectivity.status : library.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .navigationTitle("Offline")
    }

    private var playbackScreen: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                if playback.isRecording {
                    recordingControls
                } else {
                    transportControls
                    interjectionControl
                }
                chapterList
                footer
            }
            .padding(.horizontal, 8)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    playback.clearActivePackage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Items")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("LOCAL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(playback.title)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.64)
            Text(playback.progressText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            progressRail
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            iconButton(systemName: "chevron.backward", label: "Back", size: 42, prominent: false) {
                playback.skipBack()
            }
            iconButton(
                systemName: playback.isPlaying ? "pause.fill" : "play.fill",
                label: playback.isPlaying ? "Pause" : "Play",
                size: 54,
                prominent: true,
                enabled: playback.audioReady
            ) {
                playback.togglePlayback()
            }
            iconButton(systemName: "chevron.forward", label: "Forward", size: 42, prominent: false) {
                playback.skipForward()
            }
        }
    }

    private var interjectionControl: some View {
        Button {
            playback.beginInterjection()
        } label: {
            Label("Interject", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .disabled(!playback.audioReady)
        .opacity(playback.audioReady ? 1 : 0.35)
    }

    private var recordingControls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text("Recording")
                    .font(.headline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(.red.opacity(0.16), in: Capsule())

            HStack(spacing: 8) {
                actionButton(systemName: "checkmark", title: "Finish", prominent: true) {
                    playback.finishInterjection()
                }
                actionButton(systemName: "xmark", title: "Cancel", prominent: false) {
                    playback.cancelInterjection()
                }
            }
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapters")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            if playback.chapters.isEmpty {
                Text("No chapters")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(playback.chapters, id: \.id) { chapter in
                    Button {
                        playback.jump(to: chapter.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chapter.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
                                Text(timeText(chapter.startMs))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = playback.lastError ?? library.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
            } else {
                Text(playback.pendingSyncEventCount > 0 ? "\(playback.pendingSyncEventCount) queued" : playback.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
        }
    }

    private var progressRail: some View {
        GeometryReader { proxy in
            let progress = min(max(CGFloat(playback.snapshot?.sourceProgressPercent ?? 0) / 100, 0), 1)
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

    private func rowContent(_ row: WatchPackageLibraryRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: row.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color(for: row.status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                Text(actionLabel(for: row.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func iconButton(
        systemName: String,
        label: String,
        size: CGFloat,
        prominent: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 25 : 21, weight: .semibold))
                .frame(width: size, height: size)
                .background(prominent ? .white.opacity(0.36) : .white.opacity(0.13), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func actionButton(systemName: String, title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .background(prominent ? .white.opacity(0.22) : .white.opacity(0.12), in: Capsule())
    }

    private func actionLabel(for status: WatchPackageLibraryStatus) -> String {
        switch status {
        case .loadedOnWatch: return "Play"
        case .queuedForTransfer: return "Queued"
        case .availableForTransfer: return "Load to Watch"
        case .needsPrerender: return "Render"
        case .rendering: return "Rendering"
        case .failed: return "Failed"
        case .expired: return "Expired"
        }
    }

    private func iconName(for status: WatchPackageLibraryStatus) -> String {
        switch status {
        case .loadedOnWatch: return "checkmark.circle.fill"
        case .queuedForTransfer: return "arrow.down.circle"
        case .availableForTransfer: return "icloud.and.arrow.down"
        case .needsPrerender: return "wand.and.stars"
        case .rendering: return "clock.arrow.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .expired: return "hourglass"
        }
    }

    private func color(for status: WatchPackageLibraryStatus) -> Color {
        switch status {
        case .loadedOnWatch: return .green
        case .queuedForTransfer, .availableForTransfer: return .blue
        case .needsPrerender, .rendering: return .yellow
        case .failed, .expired: return .red
        }
    }

    private func timeText(_ ms: Int) -> String {
        let seconds = max(0, ms / 1000)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
