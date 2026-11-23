import SwiftUI
import UniformTypeIdentifiers
import SessionKit
import SessionKitFeeds

/// #463: follows the feeds in another app's OPML export. The listener sees what is new, already
/// followed, repeated or unusable, unticks what they don't want, and follows the rest one at a
/// time through the app's normal follow path. Nothing is added to the Library, downloaded or
/// prepared. Opens from Following and from the first-run drawer, and with a list of feed links from the
/// "Follow Podcasts in Spoken Margins" Shortcut action (#4284), or with the shows the listener's own AI suggested
/// (Following's "Suggested by your AI" row, #4683).
@MainActor
final class OPMLImportModel: ObservableObject {
    /// Where the previewed feeds came from, for the screen's words.
    enum Origin: Equatable {
        case file
        case shortcut
        /// The shows the listener's own AI suggested (#4683): a list of links, as a Shortcut's, under its own title.
        case assistant

        /// A list of links rather than a file: the screen says "list", never "file", and Cancel leaves.
        var isLinkList: Bool { self != .file }
    }

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
    @Published private(set) var origin: Origin = .file
    /// The links a Shortcut or the listener's AI passed in, as they were passed.
    private(set) var passedFeedLinks: [String] = []
    /// The preview this import showed, kept after Follow so a closed import knows what it offered.
    private var previewed: OPMLImportPreview?
    /// Called with the feed links an import followed, so they leave the AI's suggestions (#4683). Set by whoever made it.
    var onFollowed: (@MainActor ([String]) -> Void)?

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

    /// Back to "choose a file", unless a run is still following. A Shortcut's list is dropped too.
    func reset() {
        guard !isFollowing else { return }
        phase = .choosing
        selected = []
        origin = .file
        passedFeedLinks = []
        previewed = nil
    }

    func showFailure(_ error: Error) {
        guard !isFollowing else { return }
        selected = []
        phase = .failed(Self.message(for: error, origin: origin))
    }

    func load(fileAt url: URL) {
        guard !isFollowing else { return }
        origin = .file
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
        load(.file) { try OPMLParser.parse(data) }
    }

    /// The links a Shortcut (#4284) or the listener's AI (#4683) passed in, previewed exactly as the same feeds in a
    /// file would be.
    func load(feedLinks: [String], origin: Origin = .shortcut) {
        guard !isFollowing else { return }
        passedFeedLinks = feedLinks
        load(origin.isLinkList ? origin : .shortcut) { try FeedLinkListParser.parse(feedLinks) }
    }

    /// The passed links this import has settled, which leave the AI's suggestions when it closes: those it followed,
    /// and those it did not offer to follow (already followed, or unusable). Offered and not followed stays.
    func settledFeedLinks() -> [String] {
        let followed: [String]
        switch phase {
        case .following: return []
        case .finished(let result): followed = result.followed.compactMap { $0.feed?.url }
        case .choosing, .preview, .failed: followed = []
        }
        let offered = previewed?.toFollow.compactMap { $0.feed?.url } ?? []
        return AIFollowSuggestionsRow.settled(passed: passedFeedLinks, offered: offered, followed: followed)
    }

    private func load(_ origin: Origin, document: () throws -> OPMLDocument) {
        guard !isFollowing else { return }
        self.origin = origin
        previewed = nil
        if !origin.isLinkList { passedFeedLinks = [] }
        do {
            let preview = OPMLImportPlanner.preview(try document(), existing: subscriptions())
            selected = Set(preview.toFollow.map(\.id))
            previewed = preview
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
        if !result.followed.isEmpty {
            onFollowed?(result.followed.compactMap { $0.feed?.url })
            didFollow()
        }
    }

    static func message(for error: Error, origin: Origin = .file) -> String {
        switch (error as? OPMLError, origin) {
        case (.tooLarge, .assistant):
            return "Your AI's list is more than 4 MB of text, which is more than a podcast list needs. Nothing was imported."
        case (.tooManyOutlines, .assistant):
            return "Your AI's list has more than 5,000 lines. Nothing was imported."
        case (.tooLarge, .shortcut):
            return "The Shortcut passed in more than 4 MB of text, which is more than a podcast list needs. Nothing was imported."
        case (.tooManyOutlines, .shortcut):
            return "The Shortcut passed in more than 5,000 lines. Nothing was imported."
        case (.tooLarge, _):
            return "This file is larger than 4 MB, which is more than a subscription list needs. Nothing was imported."
        case (.tooManyOutlines, _):
            return "This file lists more than 5,000 entries. Nothing was imported."
        case (.tooDeep, _):
            return "This file's folders are nested too deeply to read. Nothing was imported."
        case (.notOPML, _):
            return "This isn't an OPML file. In your other app, export your subscriptions as OPML, then choose that file."
        case (.malformed, _):
            return "This OPML file is damaged or cut off, so nothing was imported. Try exporting it again."
        case (nil, _):
            return ListenerErrorText.line(prefix: "The file couldn't be read.", error: error)
        }
    }
}

struct OPMLImportScreen: View {
    /// A fresh import each time the screen opens, so an old preview never reappears.
    @StateObject private var importer: OPMLImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var isChoosingFile = false
    @State private var didOpenFilePicker = false
    /// Following's Follow sheet opens this screen from "Import from another app" (#3205): the file picker
    /// opens at once instead of waiting for a second tap.
    private let opensFilePickerOnAppear: Bool

    init(importer: @autoclosure @escaping () -> OPMLImportModel, opensFilePickerOnAppear: Bool = false) {
        _importer = StateObject(wrappedValue: importer())
        self.opensFilePickerOnAppear = opensFilePickerOnAppear
    }

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle(Self.title(for: importer.origin))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(importer.isFollowing)
            .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: OPMLImportModel.contentTypes) { result in
                switch result {
                case .success(let url): importer.load(fileAt: url)
                case .failure(let error): importer.showFailure(error)
                }
            }
            // A container, so the identifier doesn't replace the Cancel and Stop buttons' in the inset (#3818).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("opml.import.screen")
            .task {
                // Once, after the push settles: a picker raised mid-transition can be dropped.
                guard opensFilePickerOnAppear, !didOpenFilePicker else { return }
                didOpenFilePicker = true
                try? await Task.sleep(for: .milliseconds(450))
                if case .choosing = importer.phase { isChoosingFile = true }
            }
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
                Text(importer.origin.isLinkList ? "Nothing new to follow in this list." : "Nothing new to follow in this file.")
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
                countHeader(importer.origin.isLinkList ? "Repeated in the list" : "Repeated in the file", preview.duplicatesInFile.count)
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
                Button {
                    // A list of links has no file to go back to choosing: Cancel leaves the import as it is, so whoever
                    // hears it close can still read what it offered (#4683).
                    if importer.origin.isLinkList { dismiss() } else { importer.cancel() }
                } label: { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityIdentifier("opml.import.cancel")
            case .following:
                Button { importer.cancel() } label: { Text("Stop").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityIdentifier("opml.import.stop")
            case .finished:
                primaryButton("Done", id: "opml.import.done") { dismiss() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    static func title(for origin: OPMLImportModel.Origin) -> String {
        switch origin {
        case .file: return "Import from another app"
        case .shortcut: return "Import from Apple Podcasts"
        case .assistant: return AIFollowSuggestionsRow.title
        }
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
