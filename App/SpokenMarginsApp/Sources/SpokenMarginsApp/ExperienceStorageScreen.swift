import SwiftUI
import SessionKit

struct ExperienceStorageScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperienceEditorialHeader(
                        eyebrow: "One honest ledger",
                        title: "Offline storage",
                        detail: "Prepared media can be recreated. Imported audio, recordings, and Margins stay protected."
                    )
                    budgetCard
                    accounting
                    categories
                    safeClear
                }
                .padding(20)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("offlineStorage.screen")
            .navigationTitle("Offline Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.returnToSettingsFromOfflineStorage) {
                        Label("Settings", systemImage: "arrow.left")
                    }
                }
            }
            .alert("Clear reproducible audio?", isPresented: $confirmsClear) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Audio", role: .destructive, action: model.clearReproducibleOfflineAudio)
            } message: {
                Text("Up to \(bytes(snapshot.clearableBytes)) can be recreated later. Imported audiobooks, recordings, Margins, and protected active playback will remain.")
            }
            .task { model.refreshOfflineStoragePresentation() }
        }
    }

    private var budgetCard: some View {
        ExperienceSurface(tint: snapshot.currentOverageBytes > 0 ? AppColors.coral : AppColors.evergreen) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(bytes(snapshot.usedBytes))
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                    Text("used")
                        .foregroundStyle(AppColors.secondaryText)
                    Spacer()
                    Text("\(Int(usageFraction * 100))%")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(snapshot.currentOverageBytes > 0 ? AppColors.coral : AppColors.evergreen)
                }
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        storageSegment(width: geometry.size.width * protectedFraction, color: AppColors.coral)
                        storageSegment(width: geometry.size.width * reproducibleFraction, color: AppColors.evergreen)
                        storageSegment(width: geometry.size.width * reservedFraction, color: AppColors.ochre)
                    }
                }
                .frame(height: 18)
                .background(AppColors.border.opacity(0.45), in: Capsule())
                .clipShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Storage budget")
                .accessibilityValue("\(bytes(snapshot.usedBytes)) used of \(bytes(snapshot.budgetBytes)); \(bytes(snapshot.reservedBytes)) reserved")

                HStack(spacing: 14) {
                    legend("Protected", color: AppColors.coral)
                    legend("Reproducible", color: AppColors.evergreen)
                    legend("Reserved", color: AppColors.ochre)
                }

                Picker("Storage budget", selection: $model.offlineStorageLimitGB) {
                    ForEach(OfflineStorageBudget.allowedGigabytes, id: \.self) { Text("\($0) GB").tag($0) }
                }
                .pickerStyle(.menu)
                .onChange(of: model.offlineStorageLimitGB) { _, _ in model.offlineStorageBudgetChanged() }
                .accessibilityIdentifier("offlineStorage.budget.picker")

                if snapshot.currentOverageBytes > 0 {
                    Label("\(bytes(snapshot.currentOverageBytes)) over budget", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.coral)
                }
                if snapshot.residualOverageBytes > 0 {
                    Text("Even after every safely reproducible asset is cleared, \(bytes(snapshot.residualOverageBytes)) remains protected and will not be evicted automatically.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    private var accounting: some View {
        ExperienceSurface {
            VStack(spacing: 12) {
                ledgerRow("Protected or irreplaceable", value: snapshot.protectedBytes, color: AppColors.coral)
                    .accessibilityIdentifier("offlineStorage.protected.row")
                Divider()
                ledgerRow("Reproducible", value: snapshot.reproducibleBytes, color: AppColors.evergreen)
                    .accessibilityIdentifier("offlineStorage.reproducible.row")
                Divider()
                ledgerRow("Safe to clear now", value: snapshot.clearableBytes, color: AppColors.ochre)
                    .accessibilityIdentifier("offlineStorage.clearable.row")
                if snapshot.reservedBytes > 0 {
                    Divider()
                    ledgerRow("Reserved for work in progress", value: snapshot.reservedBytes, color: AppColors.ochre)
                }
            }
        }
    }

    @ViewBuilder
    private var categories: some View {
        if !snapshot.categories.isEmpty {
            Text("By category")
                .font(.system(.title2, design: .serif).weight(.bold))
            ExperienceSurface {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.categories.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(bytes(row.byteCount))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .frame(minHeight: 48)
                    }
                }
            }
        }
    }

    private var safeClear: some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.5)) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Safe clear", systemImage: "shield.checkered")
                    .font(.headline)
                    .foregroundStyle(AppColors.evergreen)
                Text("Only downloaded or generated audio that can be recreated is eligible. Original imports, recordings, Margins, and active work are excluded.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Button(role: .destructive) { confirmsClear = true } label: {
                    Label("Clear \(bytes(snapshot.clearableBytes)) of reproducible audio", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .disabled(snapshot.clearableBytes == 0)
                .accessibilityIdentifier("offlineStorage.clear.button")
            }
        }
    }

    private var snapshot: OfflineStorageSnapshot { model.offlineStorageSnapshot }
    private var usageFraction: Double { min(1, Double(snapshot.totalCommittedAndReservedBytes) / Double(max(1, snapshot.budgetBytes))) }
    private var protectedFraction: Double { min(usageFraction, Double(snapshot.protectedBytes) / Double(max(1, snapshot.budgetBytes))) }
    private var reproducibleFraction: Double { min(max(0, usageFraction - protectedFraction), Double(snapshot.reproducibleBytes) / Double(max(1, snapshot.budgetBytes))) }
    private var reservedFraction: Double { min(max(0, 1 - protectedFraction - reproducibleFraction), Double(snapshot.reservedBytes) / Double(max(1, snapshot.budgetBytes))) }

    private func storageSegment(width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width), height: 18)
    }

    private func legend(_ title: String, color: Color) -> some View {
        Label {
            Text(title).font(.caption)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }

    private func ledgerRow(_ title: String, value: Int64, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(title)
            Spacer()
            Text(bytes(value)).font(.subheadline.monospacedDigit()).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
