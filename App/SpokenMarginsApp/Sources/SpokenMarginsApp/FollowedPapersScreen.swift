import SessionKit
import SessionKitFeeds
import SwiftUI

/// A followed reading list's own screen (#4341), in the show screen's look: the list's name, "Zotero collection",
/// "Following since", Quiet, then its papers newest joined first, each with its citation, its status (PDF, Abstract
/// only or Link only, always with an icon) and one button: Add, Adding…, In Library or Open. Opening it marks the list
/// as looked at, which is what "N new papers" on Following counts from. Papers are always "Let me pick": nothing is
/// added by itself.
struct FollowedPapersScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var papers = PaperSourcesState.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let sourceID: String
    /// The Library's DOI and address index, built off the main thread when the screen opens and again after an Add.
    @State private var index: PaperLibraryIndex?

    var body: some View {
        Group {
            if let record = papers.record(id: sourceID) {
                content(record)
            } else if papers.loaded {
                // Unfollowed (here or by Undo of the follow): nothing left to show.
                Color.clear.onAppear { dismiss() }
            } else {
                ProgressView()
            }
        }
        .background(AppColors.bone)
        .accessibilityIdentifier("papers.screen")
        .task {
            await papers.load(model: model)
            await papers.markOpened(id: sourceID, model: model)
            index = await papers.libraryIndex(model: model)
        }
        // Add changes what the Library holds; the index follows so a paper added elsewhere reads In Library too.
        .task(id: model.libraryItems.count) { index = await papers.libraryIndex(model: model) }
    }

    private func content(_ record: PaperSourceRecord) -> some View {
        let rows = papers.rows(for: record, index: index)
        return List {
            header(record)
            Toggle(isOn: Binding(
                get: { record.isQuiet },
                set: { quiet in Task { await papers.setQuiet(id: record.id, quiet, model: model) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quiet").font(.body.weight(.semibold))
                    Text("Moves this list to the bottom of Following with no count.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .frame(minHeight: 44)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("papers.quiet")
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
            // The last read failed: the papers below are the last ones read, and this says why.
            if let line = papers.refreshProblemLine(id: record.id) {
                Label(line, systemImage: line == PaperSourceScreen.offlineSnapshotLine ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("papers.problem")
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
            }
            Section {
                if rows.isEmpty {
                    Text(PaperSourceScreen.emptyText(for: record.source))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
                }
                ForEach(rows) { row in
                    PaperRowView(row: row, act: { act(on: row) })
                        .listRowInsets(EdgeInsets(
                            top: 0,
                            leading: horizontalSizeClass == .regular ? 28 : 16,
                            bottom: 0,
                            trailing: horizontalSizeClass == .regular ? 28 : 16
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AppColors.bone)
                }
            } header: {
                Text("Papers")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .textCase(nil)
                    .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
            }
            Button(role: .destructive) {
                Task { await papers.unfollow(id: record.id, model: model) }
            } label: {
                Label(FollowingRowActions.unfollowTitle(showTitle: record.title), systemImage: "minus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Stops following this list. Papers already in your Library are kept. You can undo right after.")
            .accessibilityIdentifier("papers.unfollow")
            .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 4)
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable { await papers.refresh(model: model, pulled: true, only: record.id) }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ record: PaperSourceRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.text)
                .accessibilityAddTraits(.isHeader)
            Text(PaperSourceScreen.kindLine(record.source))
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            Text("Following since \(record.followedAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .experienceListBlock(horizontalSizeClass: horizontalSizeClass, verticalPadding: 8)
    }

    private func act(on row: PaperSourceScreen.Row) {
        switch row.button {
        case .add:
            Task {
                await papers.add(row.entry, model: model)
                index = await papers.libraryIndex(model: model)
            }
        case .adding:
            break
        case .inLibrary(let itemId):
            model.openItemFromTap(id: itemId)
        case .open(let url):
            if let url { openURL(url) }
        }
    }
}

/// One paper: its title on two lines, "Smith, Jones et al. · Nature · 2021", its status with an icon, and its button.
private struct PaperRowView: View {
    let row: PaperSourceScreen.Row
    let act: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.entry.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .lineLimit(2)
                if !row.entry.citationLine.isEmpty {
                    Text(row.entry.citationLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .lineLimit(2)
                }
                Label(row.statusTitle, systemImage: row.statusSymbol)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            button
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColors.panel)
        .accessibilityIdentifier("papers.row.\(row.id)")
    }

    @ViewBuilder
    private var button: some View {
        switch row.button {
        case .adding:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(row.buttonTitle).font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityElement(children: .combine)
        case .inLibrary:
            Button(action: act) {
                Label(row.buttonTitle, systemImage: "checkmark.circle")
                    .font(.caption)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Opens it in your Library.")
        case .add, .open:
            Button(action: act) {
                Text(row.buttonTitle)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityLabel("\(row.buttonTitle) \(row.entry.title)")
            .accessibilityHint(row.button == .add ? "Adds this paper to your Library." : "Opens the paper's page in Safari.")
        }
    }
}
