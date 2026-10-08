import SwiftUI
import UniformTypeIdentifiers
import SessionKit
import SessionKitFeeds

/// #463: follows the feeds in another app's OPML export. The listener sees what is new, already
/// followed, repeated or unusable, unticks what they don't want, and follows the rest one at a
/// time through the app's normal follow path. Nothing is added to the Library, downloaded or
/// prepared. Opens from Following and from the first-run drawer.
@MainActor
final class OPMLImportModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case preview(OPMLImportPreview)
        case following(done: Int, total: Int)
        case finished(OPMLImportResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .choosing
    /// Ids of the new feeds that will be followed; all of them when a file is read.
    @Published private(set) var selected: Set<String> = []

    private let subscriptions: @MainActor () -> [FeedSubscription]
    private let follow: @MainActor (String) async throws -> Void
    private let didFollow: @MainActor () -> Void
    private var run: Task<Void, Never>?

    /// - Parameters:
    ///   - subscriptions: the feeds already followed, for the preview.
    ///   - follow: follows one feed link (the drawer's path, without its per-feed refresh).
    ///   - didFollow: called once after an import that followed anything.
    init(
        subscriptions: @escaping @MainActor () -> [FeedSubscription],
        follow: @escaping @MainActor (String) async throws -> Void,
        didFollow: @escaping @MainActor () -> Void = {}
    ) {
        self.subscriptions = subscriptions
        self.follow = follow
        self.didFollow = didFollow
    }

    /// The picker accepts any file: OPML exports carry .opml, .xml or no useful type at all, and
    /// the parser turns anything else away with a plain message.
    static let contentTypes: [UTType] = [.data]

    var isFollowing: Bool {
        if case .following = phase { return true }
        return false
    }

    /// Back to "choose a file", unless a run is still following.
    func reset() {
        guard !isFollowing else { return }
        phase = .choosing
        selected = []
    }

    func showFailure(_ error: Error) {
        guard !isFollowing else { return }
        selected = []
        phase = .failed(Self.message(for: error))
    }

    func load(fileAt url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= OPMLLimits().maximumBytes else { throw OPMLError.tooLarge }
            load(data: try Data(contentsOf: url))
        } catch {
            showFailure(error)
        }
    }

    func load(data: Data) {
        guard !isFollowing else { return }
        do {
            let preview = OPMLImportPlanner.preview(try OPMLParser.parse(data), existing: subscriptions())
            selected = Set(preview.toFollow.map(\.id))
            phase = .preview(preview)
        } catch {
            showFailure(error)
        }
    }

    func isSelected(_ candidate: SourceCandidate) -> Bool { selected.contains(candidate.id) }

    func setSelected(_ candidate: SourceCandidate, _ isOn: Bool) {
        if isOn { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
    }

    /// At the preview: drops the file without following anything. While following: stops before
    /// the next feed; feeds already followed stay followed.
    func cancel() {
        if isFollowing {
            run?.cancel()
        } else {
            reset()
        }
    }

    func startFollowing() {
        guard run == nil else { return }
        run = Task { [weak self] in
            await self?.followSelected()
            self?.run = nil
        }
    }

    func followSelected() async {
        guard case .preview(let preview) = phase else { return }
        let ticked = preview.toFollow.filter { selected.contains($0.id) }
        guard !ticked.isEmpty else { return }
        phase = .following(done: 0, total: ticked.count)
        let result = await OPMLImportRunner.follow(
            preview,
            selected: selected,
            progress: { done, total in self.phase = .following(done: done, total: total) }
        ) { candidate in
            guard let feedURL = candidate.feed?.url else { throw FollowedSourceError.invalidURL }
            try await self.follow(feedURL)
        }
        phase = .finished(result)
        if !result.followed.isEmpty { didFollow() }
    }

    static func message(for error: Error) -> String {
        switch error as? OPMLError {
        case .tooLarge:
            return "This file is larger than 4 MB, which is more than a subscription list needs. Nothing was imported."
        case .tooManyOutlines:
            return "This file lists more than 5,000 entries. Nothing was imported."
        case .tooDeep:
            return "This file's folders are nested too deeply to read. Nothing was imported."
        case .notOPML:
            return "This isn't an OPML file. In your other app, export your subscriptions as OPML, then choose that file."
        case .malformed:
            return "This OPML file is damaged or cut off, so nothing was imported. Try exporting it again."
        case nil:
            return "The file couldn't be read. \(error.localizedDescription)"
        }
    }
}

struct OPMLImportScreen: View {
    /// A fresh import each time the screen opens, so an old preview never reappears.
    @StateObject private var importer: OPMLImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFile = false

    init(importer: @autoclosure @escaping () -> OPMLImportModel) {
        _importer = StateObject(wrappedValue: importer())
    }

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Import from another app")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(importer.isFollowing)
            .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: OPMLImportModel.contentTypes) { result in
                switch result {
                case .success(let url): importer.load(fileAt: url)
                case .failure(let error): importer.showFailure(error)
                }
            }
            .accessibilityIdentifier("opml.import.screen")
    }

    @ViewBuilder
    private var content: some View {
        switch importer.phase {
        case .choosing:
            Section {
                Text("In your other podcast or RSS app, export your subscriptions as an OPML file. Then choose that file here. You'll see the list before anything is followed.")
                Text("Following adds new episodes to Following only. Nothing is added to your Library or downloaded.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
        case .preview(let preview):
            previewSections(preview)
        case .following(let done, let total):
            Section {
                ProgressView(value: Double(done), total: Double(max(total, 1))) {
                    Text("Following \(min(done + 1, total)) of \(total)")
                }
                .accessibilityIdentifier("opml.import.progress")
            }
        case .finished(let result):
            resultSections(result)
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("opml.import.error")
            }
        }
    }

    @ViewBuilder
    private func previewSections(_ preview: OPMLImportPreview) -> some View {
        Section {
            if preview.toFollow.isEmpty {
                Text("Nothing new to follow in this file.")
            }
            ForEach(preview.toFollow) { candidate in
                Toggle(isOn: Binding(
                    get: { importer.isSelected(candidate) },
                    set: { importer.setSelected(candidate, $0) }
                )) {
                    feedLabel(candidate.title, detail: candidate.feed.map { URLComponents(string: $0.url)?.host ?? $0.url })
                }
                .tint(AppColors.evergreen)
                .accessibilityIdentifier("opml.import.toggle.\(candidate.title)")
            }
        } header: {
            countHeader("New", preview.toFollow.count)
        }
        if !preview.alreadyFollowed.isEmpty {
            Section {
                ForEach(Array(preview.alreadyFollowed.enumerated()), id: \.offset) { _, feed in
                    feedLabel(feed.title, detail: nil)
                }
            } header: {
                countHeader("Already followed", preview.alreadyFollowed.count)
            } footer: {
                Text("These stay as they are, including any you've muted.")
            }
        }
        if !preview.duplicatesInFile.isEmpty {
            Section {
                ForEach(Array(preview.duplicatesInFile.enumerated()), id: \.offset) { _, feed in
                    feedLabel(feed.title, detail: nil)
                }
            } header: {
                countHeader("Repeated in the file", preview.duplicatesInFile.count)
            } footer: {
                Text("Each feed is followed once.")
            }
        }
        if preview.unusableOutlineCount > 0 {
            Section {
                Text("\(preview.unusableOutlineCount) \(preview.unusableOutlineCount == 1 ? "entry has" : "entries have") no feed link Spoken Margins can use, so \(preview.unusableOutlineCount == 1 ? "it's" : "they're") skipped.")
            } header: {
                countHeader("Unusable", preview.unusableOutlineCount)
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ result: OPMLImportResult) -> some View {
        Section {
            if result.followed.isEmpty {
                Text("No feeds were followed.")
            }
            ForEach(result.followed) { candidate in
                Label(candidate.title, systemImage: "checkmark")
            }
        } header: {
            countHeader("Followed", result.followed.count)
        } footer: {
            if !result.followed.isEmpty {
                Text("New episodes show up in Following. Nothing downloads until you choose it.")
            }
        }
        if !result.failed.isEmpty {
            Section {
                ForEach(result.failed, id: \.candidate.id) { failure in
                    feedLabel(failure.candidate.title, detail: failure.reason)
                }
            } header: {
                countHeader("Couldn't follow", result.failed.count)
            }
            .accessibilityIdentifier("opml.import.failures")
        }
        if !result.notTried.isEmpty {
            Section {
                ForEach(result.notTried) { candidate in
                    feedLabel(candidate.title, detail: nil)
                }
            } header: {
                countHeader("Stopped before", result.notTried.count)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            switch importer.phase {
            case .choosing, .failed:
                primaryButton(importer.phase == .choosing ? "Choose OPML file" : "Choose another file", id: "opml.import.choose") {
                    isChoosingFile = true
                }
            case .preview:
                primaryButton(importer.selected.isEmpty ? "Follow" : "Follow \(importer.selected.count)", id: "opml.import.follow") {
                    importer.startFollowing()
                }
                .disabled(importer.selected.isEmpty)
                Button("Cancel") { importer.cancel() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("opml.import.cancel")
            case .following:
                Button("Stop") { importer.cancel() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("opml.import.stop")
            case .finished:
                primaryButton("Done", id: "opml.import.done") { dismiss() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func primaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .filledActionButton()
        .accessibilityIdentifier(id)
    }

    private func countHeader(_ title: String, _ count: Int) -> some View {
        Text("\(title) (\(count))")
    }

    private func feedLabel(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(2)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText).lineLimit(2)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}
