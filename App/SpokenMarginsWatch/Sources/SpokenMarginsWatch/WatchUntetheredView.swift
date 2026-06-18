import SessionKit
import SwiftUI

struct WatchUntetheredView: View {
    @EnvironmentObject private var model: WatchTetheredModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if model.activePackage == nil {
                library
            } else {
                playback
            }
        }
        .containerBackground(.black, for: .navigation)
        .onAppear {
            model.requestPackageLibrary()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.requestPackageLibrary()
            }
        }
    }

    private var library: some View {
        List {
            Section {
                if model.packageRows.isEmpty {
                    Text("Open iPhone to sync packages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.packageRows.enumerated()), id: \.offset) { _, row in
                        Button {
                            model.selectPackageRow(row)
                        } label: {
                            rowContent(row)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("Packages")
                    Spacer()
                    Button {
                        model.requestPackageLibrary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Offline")
    }

    private var playback: some View {
        ScrollView {
            VStack(spacing: 8) {
                header
                if model.isUntetheredRecording {
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
                    model.activePackage = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("LOCAL PACKAGE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(model.untetheredTitle)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.64)
            Text(model.untetheredProgressText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            progressRail
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            iconButton(systemName: "chevron.backward", label: "Back", size: 42, prominent: false) {
                model.skipUntetheredBack()
            }
            iconButton(
                systemName: model.isUntetheredPlaying ? "pause.fill" : "play.fill",
                label: model.isUntetheredPlaying ? "Pause" : "Play",
                size: 54,
                prominent: true
            ) {
                model.toggleUntetheredPlayback()
            }
            iconButton(systemName: "chevron.forward", label: "Forward", size: 42, prominent: false) {
                model.skipUntetheredForward()
            }
        }
    }

    private var interjectionControl: some View {
        Button {
            model.beginUntetheredInterjection()
        } label: {
            Label("Interject", systemImage: "mic.fill")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
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
                    model.finishUntetheredInterjection()
                }
                actionButton(systemName: "xmark", title: "Cancel", prominent: false) {
                    model.cancelUntetheredInterjection()
                }
            }
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapters")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            ForEach(model.activePackageChapters, id: \.id) { chapter in
                Button {
                    model.jumpUntethered(to: chapter.id)
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

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = model.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.65)
            } else {
                Text(model.pendingSyncEventCount > 0 ? "\(model.pendingSyncEventCount) queued" : model.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button {
                model.requestPackageLibrary()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private var progressRail: some View {
        GeometryReader { proxy in
            let progress = min(max(CGFloat(model.untetheredSnapshot?.sourceProgressPercent ?? 0) / 100, 0), 1)
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
                Text(label(for: row.status))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func iconButton(systemName: String, label: String, size: CGFloat, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 25 : 21, weight: .semibold))
                .frame(width: size, height: size)
                .background(prominent ? .white.opacity(0.36) : .white.opacity(0.13), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
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

    private func label(for status: WatchPackageLibraryStatus) -> String {
        switch status {
        case .loadedOnWatch: return "Loaded"
        case .queuedForTransfer: return "Queued"
        case .availableForTransfer: return "Ready to load"
        case .needsPrerender: return "Needs render"
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
