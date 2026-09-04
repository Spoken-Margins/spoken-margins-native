import SessionKit
import SwiftUI

struct ExperienceAudioPreparationQueueScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Automatic audio preparation", selection: $model.automaticAudioPreparationPolicy) {
                        ForEach(AutomaticAudioPreparationPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .onChange(of: model.automaticAudioPreparationPolicy) { _, _ in
                        model.automaticAudioPreparationPolicyChanged()
                    }

                    Text(policyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Overnight preparation")
                }

                Section {
                    if model.audioPreparationQueue.isEmpty {
                        ContentUnavailableView(
                            "Nothing queued",
                            systemImage: "moon.zzz",
                            description: Text(emptyQueueDescription)
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(model.audioPreparationQueue) { row in
                            AudioPreparationQueueItemRow(row: row)
                                .environmentObject(model)
                        }
                    }
                } header: {
                    HStack {
                        Text("Queue")
                        Spacer()
                        Text("\(model.audioPreparationQueue.count)")
                    }
                } footer: {
                    Text("The item you are listening to is pinned first. Within each remaining priority tier, use the arrows to change what iOS should prepare next.")
                }

                Section("Recently rendered") {
                    if model.recentlyPreparedAudio.isEmpty {
                        Text("Completed items will appear here after their final audio file is verified.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentlyPreparedAudio) { row in
                            Button {
                                dismiss()
                                model.openItem(id: row.itemId)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(AppColors.evergreen)
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
            .navigationTitle("Offline Rendering")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable {
                model.refreshAudioPreparationPresentation()
            }
            .task {
                model.refreshAudioPreparationPresentation()
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("offlineRendering.screen")
    }

    private var policyExplanation: String {
        if model.automaticAudioPreparationPolicy == .whileCharging {
            return "Queued text items may render while the phone is idle, connected to power, out of Low Power Mode, and within storage and thermal limits. iOS decides when background work runs, so overnight completion is not guaranteed."
        }
        return "Automatic rendering is off. Existing automatic jobs remain visible but will wait unless you render one now or turn While Charging back on."
    }

    private var emptyQueueDescription: String {
        model.automaticAudioPreparationPolicy == .whileCharging
            ? "Eligible text items are added when the library refreshes. iOS may then prepare them while charging."
            : "Choose While Charging, or use Prepare Offline on a Library item to render it now."
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
    @EnvironmentObject private var model: Gate1AppModel
    let row: AudioPreparationQueueRow

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
                        model.moveAudioPreparationJobEarlier(id: row.id)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!row.canMoveEarlier)
                    Button("Move later", systemImage: "arrow.down") {
                        model.moveAudioPreparationJobLater(id: row.id)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!row.canMoveLater)
                }
                .buttonStyle(.borderless)
            }

            if row.plannedChunkCount > 0 {
                ProgressView(value: row.progress)
                    .tint(AppColors.ochre)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer(minLength: 8)
                if row.policy != .explicit {
                    Button("Render Now") {
                        model.prioritizeOfflinePreparation(id: row.itemId)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offlineRendering.queue.\(row.itemId)")
    }

    private var priorityLabel: String {
        if row.isActivePlaybackItem { return "Now playing · first priority" }
        switch row.policy {
        case .explicit: return "Render now"
        case .demandWindow: return "Opening buffer"
        case .whileCharging: return "While charging"
        }
    }

    private var priorityIcon: String {
        if row.isActivePlaybackItem { return "pin.fill" }
        return row.policy == .explicit ? "bolt.fill" : "moon.stars.fill"
    }

    private var statusDetail: String {
        let progress = row.plannedChunkCount > 0
            ? "\(row.completedChunkCount) of \(row.plannedChunkCount) chunks"
            : "Waiting for a render plan"
        if let failureCode = row.failureCode, !failureCode.isEmpty {
            return "Waiting after \(failureCode.replacingOccurrences(of: "_", with: " ")) · \(progress)"
        }
        switch row.state {
        case .preparing:
            return progress
        case .pausedForThermal:
            return "Paused for device temperature · \(progress)"
        case .needsRepreparation:
            return "Needs an updated render · \(progress)"
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
