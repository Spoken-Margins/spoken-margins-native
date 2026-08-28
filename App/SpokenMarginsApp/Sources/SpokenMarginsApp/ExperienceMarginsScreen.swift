import SwiftUI

struct ExperienceMarginsScreen: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case attention = "Needs attention"
        case recent = "Recent"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var filter: Filter = .all
    @State private var selectedMargin: MarginRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ExperienceEditorialHeader(
                        eyebrow: "Your private commentary",
                        title: "Margins",
                        detail: "Review the thoughts you captured across every listening session."
                    )
                    summaryStrip
                    filterBar
                    collection
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, 20)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("margins.screen")
            .navigationTitle("Margins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openSettings) {
                        Image(systemName: "gearshape").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: model.refreshMarginRows) {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Refresh Margins")
                }
            }
            .task { model.refreshMarginRows() }
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row).environmentObject(model)
            }
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            summaryMetric("Total", value: model.marginRows.count, color: AppColors.coral)
            Divider().frame(height: 42)
            summaryMetric("Attention", value: attentionCount, color: attentionCount > 0 ? AppColors.coral : AppColors.evergreen)
            Divider().frame(height: 42)
            summaryMetric("Items", value: itemCount, color: AppColors.ochre)
        }
        .padding(.vertical, 14)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
    }

    private func summaryMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    Button { filter = option } label: {
                        ExperienceFilterChip(isActive: filter == option) { Text(option.rawValue) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var collection: some View {
        if filteredRows.isEmpty {
            SMExperienceEmptyState(
                systemImage: "quote.bubble",
                title: model.marginRows.isEmpty ? "No Margins yet" : "Nothing in this view",
                detail: model.marginRows.isEmpty ? "While listening, tap Interject and speak what you want to remember." : "Choose another filter to see more Margins.",
                actionTitle: model.marginRows.isEmpty ? "Open Now Playing" : "Show all"
            ) {
                if model.marginRows.isEmpty { model.openPlayback() } else { filter = .all }
            }
        } else {
            ForEach(groupedRows, id: \.title) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(group.title)
                            .font(.system(.title3, design: .serif).weight(.bold))
                        Spacer()
                        Text("\(group.rows.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().padding(.leading, 62) }
                            Button { selectedMargin = row } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: row.needsAttention ? "exclamationmark.bubble.fill" : "quote.bubble.fill")
                                        .foregroundStyle(row.needsAttention ? AppColors.coral : AppColors.ochre)
                                        .frame(width: 42, height: 42)
                                        .background((row.needsAttention ? AppColors.coral : AppColors.ochre).opacity(0.1), in: Circle())
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.preview)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(3)
                                        Text(row.needsAttention ? row.attentionDescription : "\(row.targetDescription) · \(row.interjection.roughPercent)%")
                                            .font(.caption)
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("My Margin. \(row.preview). \(row.itemTitle)")
                            .accessibilityIdentifier("margins.row.\(row.id)")
                        }
                    }
                    .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
                }
            }
        }
    }

    private var filteredRows: [MarginRow] {
        switch filter {
        case .all: model.marginRows
        case .attention: model.marginRows.filter(\.needsAttention)
        case .recent: Array(model.marginRows.prefix(12))
        }
    }

    private var groupedRows: [(title: String, rows: [MarginRow])] {
        let order = filteredRows.reduce(into: [String]()) { result, row in
            if !result.contains(row.itemTitle) { result.append(row.itemTitle) }
        }
        let groups = Dictionary(grouping: filteredRows, by: \.itemTitle)
        return order.map { ($0, groups[$0, default: []]) }
    }

    private var attentionCount: Int { model.marginRows.filter(\.needsAttention).count }
    private var itemCount: Int { Set(model.marginRows.map(\.itemTitle)).count }
}
