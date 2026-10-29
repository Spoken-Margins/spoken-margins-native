import SessionKit
import SwiftUI

struct ExperienceAudioPreparationQueueScreen: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        AudioPreparationQueueContent(
            automaticPolicy: model.automaticAudioPreparationPolicy,
            queue: model.audioPreparationQueue,
            recentlyPrepared: model.recentlyPreparedAudio,
            setAutomaticPolicy: { policy in
                model.automaticAudioPreparationPolicy = policy
                model.automaticAudioPreparationPolicyChanged()
            },
            prioritize: { id in Task { await model.prioritizeAudioPreparationJob(id: id) } },
            moveEarlier: { id in Task { await model.moveAudioPreparationJobEarlier(id: id) } },
            moveLater: { id in Task { await model.moveAudioPreparationJobLater(id: id) } },
            renderNow: model.prioritizeOfflinePreparation,
            skip: { id in Task { await model.skipAudioPreparationJob(id: id) } },
            clear: { Task { await model.clearAudioPreparationQueue() } },
            refresh: { Task { await model.refreshAudioPreparationPresentation() } },
            openItem: model.openItem
        )
        .equatable()
    }
}

private struct AudioPreparationQueueContent: View, @preconcurrency Equatable {
    let automaticPolicy: AutomaticAudioPreparationPolicy
    let queue: [AudioPreparationQueueRow]
    let recentlyPrepared: [RecentlyPreparedAudioRow]
    let setAutomaticPolicy: (AutomaticAudioPreparationPolicy) -> Void
    let prioritize: (String) -> Void
    let moveEarlier: (String) -> Void
    let moveLater: (String) -> Void
    let renderNow: (String) -> Void
    let skip: (String) -> Void
    let clear: () -> Void
    let refresh: () -> Void
    let openItem: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingQueueClear = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.automaticPolicy == rhs.automaticPolicy
            && lhs.queue == rhs.queue
            && lhs.recentlyPrepared == rhs.recentlyPrepared
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if queue.isEmpty {
                        ContentUnavailableView(
                            "Nothing queued",
                            systemImage: "moon.zzz",
                            description: Text(emptyQueueDescription)
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(queue) { row in
                            AudioPreparationQueueItemRow(
                                row: row,
                                prioritize: { prioritize(row.id) },
                                moveEarlier: { moveEarlier(row.id) },
                                moveLater: { moveLater(row.id) },
                                renderNow: { renderNow(row.itemId) },
                                skip: { skip(row.id) }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text("Queue")
                        Spacer()
                        Text("\(queue.count)")
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Use Prioritize to move an item to the top, or the arrows to adjust its position. Playback keeps priority for audio it needs immediately.")
                        if !queue.isEmpty {
                            Button("Clear Queue", role: .destructive) {
                                isConfirmingQueueClear = true
                            }
                            .accessibilityHint("Cancels queued audio preparation while keeping Library items and completed audio")
                        }
                    }
                }

                Section {
                    Picker(
                        "Automatic audio preparation",
                        selection: Binding(
                            get: { automaticPolicy },
                            set: { policy in setAutomaticPolicy(policy) }
                        )
                    ) {
                        ForEach(AutomaticAudioPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }

                    Text(policyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Automatic preparation")
                }

                Section("Recently prepared") {
                    if recentlyPrepared.isEmpty {
                        Text("Completed items will appear here after their final audio file is verified.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentlyPrepared) { row in
                            Button {
                                dismiss()
                                openItem(row.itemId)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppColors.evergreen)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.title)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                        Text(recentDetail(row))
                                            .font(.caption)
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("offlineRendering.recent.\(row.itemId)")
                        }
                    }
                }
            }
            .navigationTitle("Preparing Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable {
                refresh()
            }
            .task {
                refresh()
            }
            .confirmationDialog(
                "Clear the audio preparation queue?",
                isPresented: $isConfirmingQueueClear,
                titleVisibility: .visible
            ) {
                Button("Clear Queue", role: .destructive) {
                    clear()
                }
                Button("Keep Queue", role: .cancel) {}
            } message: {
                Text("This keeps your Library items and audio that has already been prepared. Items will not be queued again unless you explicitly choose Prepare Offline.")
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("offlineRendering.screen")
    }

    private var policyExplanation: String {
        if automaticPolicy == .whileCharging {
            return "Newly queued text items may keep preparing audio while the phone is idle, connected to power, out of Low Power Mode, and within storage and thermal limits. iOS decides when background work runs, so overnight completion is not guaranteed."
        }
        return "Automatic preparation is off. Existing automatic jobs remain visible but will wait unless you prepare one now or turn While Charging back on."
    }

    private var emptyQueueDescription: String {
        automaticPolicy == .whileCharging
            ? "New text items prepare an opening buffer when added. Choose Prepare Offline on an item to queue the rest."
            : "Choose While Charging, or use Prepare Offline on a Library item to prepare it now."
    }

    private func recentDetail(_ row: RecentlyPreparedAudioRow) -> String {
        var parts = [row.completedAt.formatted(.relative(presentation: .named))]
        if row.durationMs > 0 {
            let totalMinutes = max(1, row.durationMs / 60_000)
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            parts.append(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m")
        }
        return parts.joined(separator: " · ")
    }
}

private struct AudioPreparationQueueItemRow: View {
    let row: AudioPreparationQueueRow
    let prioritize: () -> Void
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let renderNow: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.headline)
                    Label(priorityLabel, systemImage: priorityIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.isActivePlaybackItem ? AppColors.ochre : AppColors.secondaryText)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button("Move earlier", systemImage: "arrow.up") {
                        moveEarlier()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!row.canMoveEarlier)
                    Button("Move later", systemImage: "arrow.down") {
                        moveLater()
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!row.canMoveLater)
                }
                .buttonStyle(.borderless)
            }

            if row.plannedChunkCount > 0 {
                ProgressView(value: row.progress)
                    .tint(AppColors.ochre)
                    .accessibilityLabel("Audio preparation progress")
            }

            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)

            HStack(spacing: 8) {
                Button("Prioritize", systemImage: "arrow.up.to.line") { prioritize() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .accessibilityHint("Moves this item to the top of the audio preparation queue")
                    .accessibilityIdentifier("offlineRendering.prioritize.\(row.itemId)")
                Spacer(minLength: 0)
                if row.policy != .explicit {
                    Button("Prepare Now") {
                        renderNow()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }
                Button("Don't Prepare", role: .destructive) {
                    skip()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offlineRendering.queue.\(row.itemId)")
    }

    private var priorityLabel: String {
        if row.isActivePlaybackItem { return "Now playing" }
        switch row.policy {
        case .explicit: return "Prepare now"
        case .demandWindow: return "Opening audio"
        case .whileCharging: return "While charging"
        }
    }

    private var priorityIcon: String {
        if row.isActivePlaybackItem { return "play.fill" }
        return row.policy == .explicit ? "bolt.fill" : "moon.stars.fill"
    }

    private var statusDetail: String {
        let progress = row.plannedChunkCount > 0
            ? "\(row.completedChunkCount) of \(row.plannedChunkCount)"
            : "Waiting"
        if row.failureCode == OfflinePreparationRecovery.waitingForSystem {
            return "Background time ended; will retry when iOS allows while charging · \(progress)"
        }
        if let failureCode = row.failureCode, !failureCode.isEmpty {
            return "Waiting after \(failureCode.replacingOccurrences(of: "_", with: " ")) · \(progress)"
        }
        switch row.state {
        case .preparing:
            return progress
        case .pausedForThermal:
            return "Paused for device temperature · \(progress)"
        case .needsRepreparation:
            return "Needs preparing again · \(progress)"
        case .stopped:
            return "Stopped · \(progress)"
        case .failed:
            return "Paused after an error · \(progress)"
        case .notPrepared:
            return "Queued · \(progress)"
        case .readyOffline:
            return "Finishing verified audio"
        }
    }
}
