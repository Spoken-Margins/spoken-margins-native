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
    @Published var selectedSubject: String?
    @Published private(set) var catalog: SourceCatalog?
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

    var entries: [SourceCatalogEntry] { catalog?.entries(forSubject: selectedSubject) ?? [] }
    var subjects: [SourceCatalogSubject] { catalog?.visibleSubjects ?? [] }
    var followedCount: Int { followStates.values.filter { $0 == .followed }.count }

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

    func state(for entry: SourceCatalogEntry) -> FollowState? {
        if let state = followStates[entry.id] { return state }
        guard let catalog else { return nil }
        let recorded = (defaults.dictionary(forKey: Self.followedSourcesKey) as? [String: String])?[entry.id]
        return CatalogFollowState.isFollowed(entry, in: catalog, recordedSourceId: recorded, subscriptions: subscriptions())
            ? .followed : nil
    }

    /// Follow state for every row in one pass (#246); rows without a state are left out.
    func followStates(for entries: [SourceCatalogEntry]) -> [String: FollowState] {
        var states: [String: FollowState] = [:]
        for entry in entries {
            if let state = state(for: entry) { states[entry.id] = state }
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
            .navigationTitle("Follow a few podcasts")
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
            List {
                Section {
                    ForEach(drawer.entries) { entry in
                        CatalogDrawerRow(entry: entry)
                    }
                } header: {
                    Text("New episodes show up in Following. Nothing downloads until you choose it.")
                        .font(.footnote)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                if drawer.followedCount > 0 {
                    Text("Following \(drawer.followedCount) \(drawer.followedCount == 1 ? "show" : "shows")")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.bar)
                        .accessibilityIdentifier("catalog.drawer.followedCount")
                }
            }
        }
    }
}

private struct CatalogDrawerRow: View {
    @EnvironmentObject private var drawer: CatalogDrawerModel
    let entry: SourceCatalogEntry

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: entry.artworkURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                AppColors.panel.overlay { Image(systemName: "headphones").foregroundStyle(AppColors.secondaryText) }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline).lineLimit(2)
                if let author = entry.author {
                    Text(author).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(1)
                }
                if case .failed(let message) = drawer.state(for: entry) {
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
        switch drawer.state(for: entry) {
        case .following:
            ProgressView().frame(minWidth: 96, minHeight: 44)
        case .followed:
            Label("Following", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.followed.\(entry.id)")
        case .failed:
            Button("Retry") { drawer.toggleFollow(entry) }
                .buttonStyle(.bordered)
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        case nil:
            Button("Follow") { drawer.toggleFollow(entry) }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .frame(minWidth: 96, minHeight: 44)
                .accessibilityLabel("Follow \(entry.title)")
                .accessibilityIdentifier("catalog.follow.\(entry.id)")
        }
    }
}
