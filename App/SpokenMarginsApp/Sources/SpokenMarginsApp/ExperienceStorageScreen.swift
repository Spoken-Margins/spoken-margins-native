import SwiftUI
import SessionKit

struct ExperienceStorageScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var confirmsClear = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    budgetCard
                    safeClear
                    accounting
                    categories
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
            .miniPlayerKeepOut()
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
                        StorageSwatch(kind: .protected).frame(width: max(0, geometry.size.width * protectedFraction), height: 18)
                        StorageSwatch(kind: .reproducible).frame(width: max(0, geometry.size.width * reproducibleFraction), height: 18)
                        StorageSwatch(kind: .reserved).frame(width: max(0, geometry.size.width * reservedFraction), height: 18)
                    }
                }
                .frame(height: 18)
                .background(AppColors.border.opacity(0.45), in: Capsule())
                .clipShape(Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Storage budget")
                .accessibilityValue("\(bytes(snapshot.usedBytes)) used of \(bytes(snapshot.budgetBytes)); \(bytes(snapshot.reservedBytes)) reserved")

                // Each part is named with its size and drawn solid, striped or dotted, so the bar
                // never relies on colour alone (#503).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legendItems }
                    VStack(alignment: .leading, spacing: 6) { legendItems }
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
                ledgerRow("Protected or irreplaceable", value: snapshot.protectedBytes, kind: .protected)
                    .accessibilityIdentifier("offlineStorage.protected.row")
                Divider()
                ledgerRow("Reproducible", value: snapshot.reproducibleBytes, kind: .reproducible)
                    .accessibilityIdentifier("offlineStorage.reproducible.row")
                Divider()
                ledgerRow("Safe to clear now", value: snapshot.clearableBytes, kind: .reproducible)
                    .accessibilityIdentifier("offlineStorage.clearable.row")
                if snapshot.reservedBytes > 0 {
                    Divider()
                    ledgerRow("Reserved for work in progress", value: snapshot.reservedBytes, kind: .reserved)
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

    @ViewBuilder
    private var legendItems: some View {
        legend("Protected", value: snapshot.protectedBytes, kind: .protected)
        legend("Reproducible", value: snapshot.reproducibleBytes, kind: .reproducible)
        legend("Reserved", value: snapshot.reservedBytes, kind: .reserved)
    }

    private func legend(_ title: String, value: Int64, kind: StorageSwatch.Kind) -> some View {
        Label {
            Text("\(title) \(bytes(value))").font(.caption)
        } icon: {
            StorageSwatch(kind: kind).frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private func ledgerRow(_ title: String, value: Int64, kind: StorageSwatch.Kind) -> some View {
        HStack {
            StorageSwatch(kind: kind).frame(width: 14, height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
            Text(title)
            Spacer()
            Text(bytes(value)).font(.subheadline.monospacedDigit()).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// One part of the storage bar. Protected is solid plum, Reproducible striped evergreen and Reserved
/// dotted ochre: a red-green colour-blind listener tells them apart by pattern and by the sizes named
/// in the legend, not by hue (#503).
private struct StorageSwatch: View {
    enum Kind { case protected, reproducible, reserved }
    let kind: Kind

    var body: some View {
        switch kind {
        case .protected:
            AppColors.plum
        case .reproducible:
            AppColors.evergreen.overlay { DiagonalStripes().stroke(AppColors.bone.opacity(0.75), lineWidth: 2) }.clipped()
        case .reserved:
            AppColors.ochre.overlay { Dots().fill(AppColors.bone.opacity(0.75)) }.clipped()
        }
    }

    private struct DiagonalStripes: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 6
            }
            return path
        }
    }

    private struct Dots: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var y = rect.minY + 2.5
            while y < rect.maxY {
                var x = rect.minX + 2.5
                while x < rect.maxX {
                    path.addEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                    x += 5
                }
                y += 5
            }
            return path
        }
    }
}
