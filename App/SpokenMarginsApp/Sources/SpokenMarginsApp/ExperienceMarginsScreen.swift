import SwiftUI

struct ExperienceMarginsScreen: View {
    private struct MarginGroup: Identifiable {
        let itemID: String
        let itemTitle: String
        let rows: [MarginRow]

        var id: String { itemID }


    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TextField("Search your notes or an item", text: $model.marginCollectionQuery.text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("margins.search.field")
                        .padding(.bottom, 12)
                    HStack {
                        Picker("Scope", selection: $model.marginCollectionQuery.itemID) {
                            Text("All items").tag(String?.none)
                            ForEach(model.marginScopeItems) { item in Text(item.title).tag(Optional(item.id)) }
                        }
                        .accessibilityIdentifier("margins.scope.picker")
                        Spacer()
                        Text("\(model.marginCollectionQuery.filter == .shared ? model.visibleSharedMarginRows.count : filteredRows.count) Margins")
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                    filterBar
                        .padding(.bottom, 8)
                    if model.marginCollectionQuery.filter == .shared { sharedCollection } else { collection }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, 12)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityElement(children: .contain)
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
                    Button("Export Sessions", systemImage: "square.and.arrow.up.on.square", action: model.openBatchExport)
                        .accessibilityIdentifier("margins.export.button")
                }
            }
            .task { model.refreshMarginRows() }
            .refreshable { model.refreshMarginRows() }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row).environmentObject(model)
            }
            .sheet(item: $selectedSharedMargin) { row in
                SharedMarginDetailView(row: row).environmentObject(model)
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MarginCollectionFilter.allCases.filter { $0 != .attention }, id: \.self) { option in
                    Button { model.marginCollectionQuery.filter = option } label: {
                        ExperienceFilterChip(isActive: model.marginCollectionQuery.filter == option) { Text(option.title) }
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
                detail: model.marginRows.isEmpty ? "While listening, record or write what you want to remember." : "Try a different search or filter.",
                actionTitle: model.marginRows.isEmpty ? (model.hasActiveSession ? "Open Now Playing" : "Choose an item") : "Clear search & filters"
            ) {
                if model.marginRows.isEmpty {
                    if model.hasActiveSession { model.openPlayback() } else { model.openLibrary() }
                } else { model.marginCollectionQuery = MarginCollectionQuery() }
            }
        } else {
            ForEach(groupedRows) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.itemTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(group.rows.count) Margins")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Button { model.openMarginItemExport(itemID: group.itemID) } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Share Margins from \(group.itemTitle)")
                    .accessibilityIdentifier("margins.shareItem.\(group.itemID)")
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    ForEach(group.rows) { row in
                        Button { selectedMargin = row } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.interjection.isStarredForSharing == true ? "star.fill" : (row.needsAttention ? "exclamationmark.bubble.fill" : (row.isWritten ? "square.and.pencil" : "quote.bubble")))
                                    .foregroundStyle(row.needsAttention ? AppColors.coral : AppColors.evergreen)
                                    .frame(width: 28, height: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.preview)
                                        .font(.system(.body, design: .serif))
                                        .foregroundStyle(AppColors.text)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(3)
                                    Text(row.needsAttention ? row.attentionDescription : "\(row.targetDescription) · \(row.interjection.roughPercent)%")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("My Margin. \(row.preview). \(group.itemTitle). \(row.sessionDate?.formatted(date: .abbreviated, time: .shortened) ?? "Listening session")")
                        .accessibilityIdentifier("margins.row.\(row.id)")
                        .contextMenu {
                            Button("Play this moment", systemImage: "play.fill") { _ = model.playMarginMoment(row) }
                            Button("Copy with Context", systemImage: "doc.on.doc") { model.copyInterjectionWithContext(row.interjection) }
                            Button(row.interjection.isStarredForSharing == true ? "Unstar" : "Star", systemImage: "star") {
                                model.setInterjectionStarredForSharing(row.interjection.id, sessionId: row.interjection.sessionId, starred: row.interjection.isStarredForSharing != true)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(AppColors.border.opacity(0.75)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharedCollection: some View {
        if model.visibleSharedMarginRows.isEmpty {
            ContentUnavailableView(
                model.marginCollectionQuery.text.isEmpty ? "No shared Margins" : "No matches",
                systemImage: "person.2",
                description: Text("Imported Margins appear here separately from your own notes.")
            )
        } else {
            ForEach(model.visibleSharedMarginRows) { row in
                Button { selectedSharedMargin = row } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Shared · \(row.collectionLabel)", systemImage: "person.2")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Text(row.interjection.approvedTranscript)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(3)
                        Text("\(row.itemTitle) · \(row.positionDescription)")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("margins.shared.row.\(row.id)")
                Divider()
            }
        }
    }

    private var filteredRows: [MarginRow] { model.visiblePrivateMarginRows }

    private var groupedRows: [MarginGroup] {
        let orderedItemIDs = filteredRows.reduce(into: [String]()) { result, row in
            if !result.contains(row.interjection.itemId) { result.append(row.interjection.itemId) }
        }
        let rowsByItem = Dictionary(grouping: filteredRows, by: \.interjection.itemId)
        return orderedItemIDs.compactMap { itemID in
            guard let rows = rowsByItem[itemID], let first = rows.first else { return nil }
            return MarginGroup(itemID: itemID, itemTitle: first.itemTitle, rows: rows)
        }
    }

}

struct SharedMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shouldOpenItem = false
    let row: SharedMarginRow

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Shared · \(row.collectionLabel)", systemImage: "person.2")
                        .font(.subheadline)
                    Text(row.interjection.approvedTranscript)
                        .font(.system(.title3, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Source & position") {
                    Text(row.itemTitle)
                    Text(row.positionDescription)
                    if row.layer.itemId != nil {
                        Button("Open item and shared controls", systemImage: "doc.text") {
                            shouldOpenItem = true
                            dismiss()
                        }
                    } else {
                        Text("The source is missing. Open the original shared file to match it.")
                    }
                }
                Section {
                    DisclosureGroup("Package details") {
                        Text("Package integrity checked. Sender identity is unverified; this does not restrict playback.")
                        Text("Imported \(row.layer.importedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle("Shared Margin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onDisappear {
                if shouldOpenItem, let itemID = row.layer.itemId { model.openItem(id: itemID) }
            }
        }
    }
}
