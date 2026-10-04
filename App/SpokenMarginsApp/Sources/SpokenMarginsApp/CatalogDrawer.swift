import SwiftUI
import SessionKit

/// B1 M1: the first-run drawer of popular podcasts. It reads the bundled catalog snapshot
/// (works offline), refreshes from the remote catalog when online, and follows a show in one
/// tap through the app's normal follow path.
@MainActor
final class CatalogDrawerModel: ObservableObject {
    enum FollowState: Equatable {
        case following
        case followed
        case failed(String)
    }

    static let seenKey = "catalogDrawerSeenV1"
    /// Catalog entry id → followed source id, recorded when the drawer follows a show.
    static let followedSourcesKey = "catalogDrawerFollowedSourcesV1"

    @Published var isPresented = false
    @Published var selectedSubject: String? { didSet { refreshEntries() } }
    @Published private(set) var catalog: SourceCatalog? { didSet { refreshEntries() } }
    /// The rows for the selected subject, refiltered only when the catalog or subject changes
    /// (#246: it was refiltered on every render, including one per Follow tap).
    @Published private(set) var entries: [SourceCatalogEntry] = []
    @Published private(set) var loadError: String?
    @Published private(set) var followStates: [String: FollowState] = [:]

    private let store: SourceCatalogStore?
    private let follow: @MainActor (String) async throws -> String
    private let subscriptions: @MainActor () -> [FeedSubscription]
    private let defaults: UserDefaults
    private var hasLoaded = false

    init(
        store: SourceCatalogStore?,
        defaults: UserDefaults = .standard,
        subscriptions: @escaping @MainActor () -> [FeedSubscription],
        follow: @escaping @MainActor (String) async throws -> String
    ) {
        self.store = store
        self.defaults = defaults
        self.subscriptions = subscriptions
        self.follow = follow
    }

    /// The app's drawer: the bundled snapshot plus a cache in Application Support.
    static func makeStore() -> SourceCatalogStore? {
        guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            return configuration
        }())
        return SourceCatalogStore(
            bundledCatalogURL: bundled,
            cacheDirectory: support.appending(path: "SourceCatalog", directoryHint: .isDirectory)
        ) { url, maximumBytes in
            let (data, response) = try await session.data(from: url)
            guard data.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
    }

    var subjects: [SourceCatalogSubject] { catalog?.visibleSubjects ?? [] }
    var followedCount: Int { followStates.values.filter { $0 == .followed }.count }
    /// The footer, counting shows and newsletters in their own words (#661).
    var followedSummary: String? {
        let followed = (catalog?.entries ?? []).filter { followStates[$0.id] == .followed }
        return CatalogFollowedSummary.text(followedKinds: followed.map(\.contentKind))
    }

    func presentIfFirstRun(libraryWasEmptyAtLaunch: Bool, followedSourceCount: Int) {
        guard FirstRunCatalogDrawerPolicy.opensAutomatically(
            libraryWasEmptyAtLaunch: libraryWasEmptyAtLaunch,
            hasSeenDrawer: defaults.bool(forKey: Self.seenKey),
            followedSourceCount: followedSourceCount
        ) else { return }
        present()
    }

    func present() {
        isPresented = true
    }

    /// Called when the sheet closes, however it closes.
    func markSeen() {
        defaults.set(true, forKey: Self.seenKey)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let store else {
            loadError = "The podcast list isn't available in this build."
            return
        }
        do {
            catalog = try await store.current()
        } catch {
            loadError = "The podcast list couldn't be read."
            return
        }
        if case .updated = await store.refresh() {
            catalog = (try? await store.current()) ?? catalog
        }
    }

    /// The stored catalog for Following's kind and subject tags (#485): no refresh, and it
    /// doesn't count as the drawer's load, so opening the drawer still refreshes it.
    func loadSnapshot() async {
        guard catalog == nil, let store, let snapshot = try? await store.current() else { return }
        if catalog == nil { catalog = snapshot }
    }

    private func refreshEntries() {
        entries = catalog?.entries(forSubject: selectedSubject) ?? []
    }

    func state(for entry: SourceCatalogEntry) -> FollowState? {
        followStates(for: [entry])[entry.id]
    }

    /// Follow state for every row in one pass (#246); rows without a state are left out. The list
    /// asks once per render, so the recorded follows and the subscriptions are read once, not
    /// twice per row. Subscriptions aren't cached: they change in Following without telling
    /// the drawer.
    func followStates(for entries: [SourceCatalogEntry]) -> [String: FollowState] {
        var states: [String: FollowState] = [:]
        if let catalog, entries.contains(where: { followStates[$0.id] == nil }) {
            let recorded = defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String] ?? [:]
            let followed = CatalogFollowState.followedEntryIds(in: catalog, recordedSourceIds: recorded, subscriptions: subscriptions())
            for entry in entries where followed.contains(entry.id) {
                states[entry.id] = .followed
            }
        }
        for entry in entries {
            if let state = followStates[entry.id] { states[entry.id] = state }
        }
        return states
    }

    private func recordFollowedSource(_ sourceId: String, for entry: SourceCatalogEntry) {
        var recorded = defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String] ?? [:]
        recorded[entry.id] = sourceId
        defaults.set(recorded, forKey: Self.followedSourcesKey)
    }

    func toggleFollow(_ entry: SourceCatalogEntry) {
        switch state(for: entry) {
        case .following, .followed:
            return
        case .failed, nil:
            break
        }
        followStates[entry.id] = .following
        Task { [weak self] in
            guard let self else { return }
            do {
                let sourceId = try await self.follow(entry.feedURL)
                self.recordFollowedSource(sourceId, for: entry)
                self.followStates[entry.id] = .followed
            } catch {
                self.followStates[entry.id] = .failed(error.localizedDescription)
            }
        }
    }
}

struct CatalogDrawerView: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                subjectBar
                list
            }
            .background(AppColors.bone)
            .navigationTitle("Follow a few favourites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { drawer.isPresented = false }
                        .accessibilityIdentifier("catalog.drawer.done")
                }
            }
            .task { await drawer.load() }
        }
        .accessibilityIdentifier("catalog.drawer")
    }

    private var subjectBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                subjectChip(id: nil, title: "Top")
                ForEach(drawer.subjects) { subject in
                    subjectChip(id: subject.id, title: subject.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func subjectChip(id: String?, title: String) -> some View {
        let isSelected = drawer.selectedSubject == id
        return Button { drawer.selectedSubject = id } label: {
            HStack(spacing: 4) {
                if isSelected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(title).font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? AppColors.evergreen.opacity(0.16) : AppColors.panel, in: Capsule())
            .overlay { Capsule().stroke(isSelected ? AppColors.evergreen : AppColors.border) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("catalog.subject.\(id ?? "top")")
    }

    @ViewBuilder
    private var list: some View {
        if let loadError = drawer.loadError {
            ContentUnavailableView("No podcast list", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if drawer.catalog == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let states = drawer.followStates(for: drawer.entries)
            List {
                Section {
                    ForEach(drawer.entries) { entry in
                        CatalogDrawerRow(entry: entry, state: states[entry.id]) { drawer.toggleFollow(entry) }
                            .equatable()
                    }
                } header: {
                    Text("New episodes and posts show up in Following. Nothing downloads until you choose it.")
                        .font(.footnote)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                if let summary = drawer.followedSummary {
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.bar)
                        .accessibilityIdentifier("catalog.drawer.followedCount")
                }
            }
        }
    }
}

/// One drawer row. It gets its follow state from the list's single pass instead of observing the
/// drawer, so a Follow tap re-renders only the row whose state changed (#246).
private struct CatalogDrawerRow: View, Equatable {
    let entry: SourceCatalogEntry
    let state: CatalogDrawerModel.FollowState?
    let toggleFollow: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.state == rhs.state
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: entry.artworkURL.flatMap(URL.init(string:)))
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(2)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                }
                if case .failed(let message) = state {
                    Text(message).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            followButton
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var followButton: some View {
        switch state {
        case .following:
            ProgressView().frame(minWidth: 96, minHeight: 44)
        case .followed:
            Label("Following", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.followed.\(entry.id)")
        case .failed:
            Button("Retry", action: toggleFollow)
                .buttonStyle(.bordered)
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        case nil:
            Button("Follow", action: toggleFollow)
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityLabel("Follow \(entry.title)")
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        }
    }
}
