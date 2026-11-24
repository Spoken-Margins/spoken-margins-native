import SwiftUI
import SessionKit

/// One pack on the drawer's Packs chip (#4285 §2a): its own section with two rows, so a tap on one can never reach the
/// other. Row 1 opens the Pack screen; row 2 is the pack button.
struct CatalogPackSection: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    let pack: SourceCatalogPack

    var body: some View {
        Section {
            NavigationLink(value: CatalogDrawerRoute.pack(pack.id)) {
                CatalogPackCard(pack: pack, sources: drawer.visibleSources(of: pack), footnote: drawer.footnote(for: pack))
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("catalog.pack.\(pack.id)")
            CatalogPackButton(pack: pack)
                .listRowBackground(Color.clear)
        }
    }
}

/// A pack card's first row: name, summary, `<pace> · <N shows>, <M newsletters>`, and up to six artwork thumbnails
/// then "+K". At accessibility sizes the thumbnails go and the lines wrap with no limit.
private struct CatalogPackCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let pack: SourceCatalogPack
    let sources: [SourceCatalogEntry]
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pack.title).font(.headline)
            Text(pack.summary).font(.subheadline).foregroundStyle(AppColors.secondaryText)
            Text(footnote).font(.footnote).foregroundStyle(AppColors.secondaryText)
            if !dynamicTypeSize.isAccessibilitySize, !sources.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sources.prefix(CatalogPackWords.artworkStripLimit), id: \.id) { source in
                        ArtworkThumbnail(url: source.artworkURL.flatMap(URL.init(string:)))
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    if let overflow = CatalogPackWords.artworkOverflow(sourceCount: sources.count) {
                        Text(overflow).font(.footnote.weight(.semibold)).foregroundStyle(AppColors.secondaryText)
                    }
                }
                .padding(.top, 4)
                .accessibilityHidden(true)
            }
        }
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CatalogPackWords.cardAccessibilityLabel(title: pack.title, summary: pack.summary, footnote: footnote))
        .accessibilityAddTraits(.isButton)
    }
}

/// The pack button (#4285 §2a), first match wins: Following… (disabled), Retry R with a footnote, Following all N
/// (static), Follow the other N−k, Follow all N.
struct CatalogPackButton: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    let pack: SourceCatalogPack

    var body: some View {
        let state = drawer.buttonState(for: pack)
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .following:
                HStack(spacing: 8) {
                    ProgressView()
                    Text(CatalogPackWords.buttonTitle(state))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityElement(children: .combine)
            case .followedAll:
                Label(CatalogPackWords.buttonTitle(state), systemImage: "checkmark")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            case .retry(let failed):
                followButton(title: CatalogPackWords.buttonTitle(state))
                Text(CatalogPackWords.retryFootnote(failed: failed))
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            case .followRest, .followAll:
                followButton(title: CatalogPackWords.buttonTitle(state))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalog.pack.\(pack.id).followAll")
    }

    private func followButton(title: String) -> some View {
        Button { drawer.followAll(pack) } label: {
            Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .filledActionButton()
    }
}

/// The Pack screen (#4285 §2b), pushed inside the drawer: summary, pace, the pack button and a note, then one row per
/// visible source in §2f order with its pace, Follow control and a More menu (Unfollow, Not for me).
struct CatalogPackScreen: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    let packId: String

    var body: some View {
        Group {
            if let pack = drawer.pack(id: packId) {
                let sources = drawer.visibleSources(of: pack)
                if sources.isEmpty {
                    ContentUnavailableView(
                        CatalogPackWords.packEmptyTitle,
                        systemImage: "eye.slash",
                        description: Text(CatalogPackWords.packEmptyDescription)
                    )
                } else {
                    content(pack: pack, sources: sources)
                }
            } else {
                ContentUnavailableView(CatalogPackWords.packEmptyTitle, systemImage: "eye.slash")
            }
        }
        .background(AppColors.bone)
        .navigationTitle(drawer.pack(id: packId)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { CatalogDrawerBottomInset() }
        .toolbar { CatalogDrawerDoneButton() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("catalog.packScreen")
    }

    private func content(pack: SourceCatalogPack, sources: [SourceCatalogEntry]) -> some View {
        let states = drawer.followStates(for: sources)
        return List {
            // Each control is its own row.
            Section {
                Text(pack.summary).font(.body)
                Text(drawer.footnote(for: pack)).font(.footnote).foregroundStyle(AppColors.secondaryText)
                CatalogPackButton(pack: pack)
                Text(CatalogPackWords.followingNote).font(.footnote).foregroundStyle(AppColors.secondaryText)
            }
            .listRowBackground(Color.clear)
            Section {
                ForEach(sources, id: \.id) { entry in
                    CatalogPackSourceRow(entry: entry, state: states[entry.id], pace: drawer.paceWords(for: entry))
                }
            } footer: {
                Text(CatalogPackWords.packScreenFooter).font(.footnote)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// One source on the Pack screen.
private struct CatalogPackSourceRow: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: SourceCatalogEntry
    let state: CatalogDrawerFollowState?
    let pace: String?

    var body: some View {
        CatalogShowRowLayout(artworkURL: entry.artworkURL.flatMap(URL.init(string:))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                }
                if let pace {
                    Text(pace).font(.footnote).foregroundStyle(AppColors.secondaryText)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
                }
            }
        } control: {
            HStack(spacing: 4) {
                followControl
                moreMenu
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .accessibilityActions {
            if state == .followed {
                Button(CatalogPackWords.unfollowTitle) { drawer.unfollowFromPack(entry) }
            }
            Button(FollowingDismissMessages.notForMeTitle) { drawer.notForMeFromPack(entry) }
        }
    }

    @ViewBuilder
    private var followControl: some View {
        switch state {
        case .following:
            ProgressView().frame(minWidth: 96, minHeight: 44)
                .accessibilityLabel("Following \(entry.title)")
        case .followed:
            Label("Following", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.followed.\(entry.id)")
        case .failed:
            Button { drawer.toggleFollow(entry) } label: {
                Text("Retry").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Retry following \(entry.title)")
            .accessibilityIdentifier("catalog.follow.\(entry.id)")
        case nil:
            Button { drawer.toggleFollow(entry) } label: {
                Text("Follow").frame(minWidth: 96, minHeight: 44).contentShape(Rectangle())
            }
            .filledActionButton()
            .accessibilityLabel("Follow \(entry.title)")
            .accessibilityIdentifier("catalog.follow.\(entry.id)")
        }
    }

    private var moreMenu: some View {
        Menu {
            if state == .followed {
                Button(CatalogPackWords.unfollowTitle, systemImage: "minus.circle") { drawer.unfollowFromPack(entry) }
            }
            Button(FollowingDismissMessages.notForMeTitle, systemImage: FollowingDismissMessages.notForMeSystemImage, role: .destructive) {
                drawer.notForMeFromPack(entry)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(CatalogPackWords.moreActionsLabel)
        .accessibilityHint(entry.title)
        .accessibilityIdentifier("catalog.pack.\(entry.id).more")
    }
}

/// The Not for me screen (#4285 §2c): each hidden source with Show again, newest first. Show again removes the hide
/// and doesn't follow; when the last row goes, the screen pops back.
struct CatalogNotForMeScreen: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    @Environment(\.dismiss) private var dismiss
    @State private var hasLoaded = false

    var body: some View {
        List {
            Section {
                ForEach(drawer.hiddenSources, id: \.feedKey) { source in
                    row(source)
                }
            } footer: {
                Text(CatalogPackWords.notForMeScreenFooter).font(.footnote)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(CatalogPackWords.notForMeScreenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await drawer.reloadHiddenSources()
            hasLoaded = true
        }
        .toolbar { CatalogDrawerDoneButton() }
        .onChange(of: drawer.hiddenSources.isEmpty) { _, isEmpty in
            if isEmpty, hasLoaded { dismiss() }
        }
        .accessibilityIdentifier("catalog.notForMeScreen")
    }

    private func row(_ source: NotForMeStore.HiddenSource) -> some View {
        CatalogShowRowLayout(artworkURL: source.artworkURL.flatMap(URL.init(string:))) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title).font(.headline)
                Text(CatalogPackWords.hiddenOn(source.hiddenAt)).font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        } control: {
            Button {
                Task { await drawer.showAgain(source, feedURL: drawer.feedURL(for: source)) }
            } label: {
                Text(CatalogPackWords.showAgainTitle).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(CatalogPackWords.showAgainTitle), \(source.title)")
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }
}

/// The drawer's Done, kept in the toolbar of the screens pushed inside it (#4285 §2b).
struct CatalogDrawerDoneButton: ToolbarContent {
    @EnvironmentObject private var drawer: CatalogDrawerModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { drawer.finish() }
                .accessibilityIdentifier("catalog.drawer.done")
        }
    }
}
