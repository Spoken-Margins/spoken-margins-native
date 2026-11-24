import SessionKit
import SessionKitPersistence
import SwiftUI

/// "Find in text" (#5035): a sheet over the player that finds a typed phrase in the item's stored text and, on a tap,
/// moves playback there with the Timeline row's existing seek (`Gate1AppModel.seekText`). Presentation only: it holds
/// no playback state, never starts playback, and reads (never writes) the stored text and document.
struct FindInTextSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = FindInTextViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(FindInTextPresentation.fieldPlaceholder, text: $search.query, identifier: "playback.findInText.field")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                content
            }
            .background(AppColors.listeningBackground.ignoresSafeArea())
            .searchKeyboardDoneBar()
            .navigationTitle(FindInTextPresentation.buttonLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("playback.findInText.done")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: model.selectedItem.id) {
            search.load(text: model.selectedItem.text, chapters: model.selectedItem.chapters,
                        itemId: model.selectedItem.id, store: model.store)
        }
        .onChange(of: search.query) { _, _ in search.run() }
    }

    @ViewBuilder private var content: some View {
        if FindInTextPresentation.buttonState(isRecordedAudio: model.selectedItem.isNativeAudio,
                                              text: model.selectedItem.text) == .preparing {
            Text(FindInTextPresentation.preparingText)
                .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Spacer()
        } else if let empty = FindInTextPresentation.emptyText(query: search.query, result: search.result) {
            Text(empty)
                .font(.subheadline).foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .accessibilityIdentifier("playback.findInText.empty")
            Spacer()
        } else {
            List {
                ForEach(Array(search.result.matches.enumerated()), id: \.offset) { index, match in
                    Button { select(match) } label: { FindInTextRow(match: match) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(FindInTextPresentation.accessibilityLabel(for: match))
                        .accessibilityIdentifier("playback.findInText.result.\(index)")
                        .listRowBackground(Color.clear)
                }
                if let cap = FindInTextPresentation.capText(for: search.result) {
                    Text(cap).font(.footnote).foregroundStyle(AppColors.secondaryText)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("playback.findInText.cap")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The Timeline row's seek, then close. No play call when the item is loaded: a paused item stays paused. An item
    /// the player doesn't hold is opened first by the Timeline's "Play source from beginning" call, and the seek runs
    /// only if that open loaded it (the engine's text seek never checks item ids).
    private func select(_ match: ItemTextSearch.Match) {
        let searchedId = model.selectedItem.id
        if FindInTextSeekPlan.plan(loadedItemId: model.snapshot.itemId, selectedItemId: searchedId) == .openThenSeek {
            model.playSourceFromBeginning(fromTimeline: true)
        }
        // The open may have returned early (Terms gate) or thrown, leaving another item loaded; the engine's text seek
        // would then move that item and save its place. A queued open plays as it would.
        if FindInTextSeekPlan.shouldSeek(loadedItemId: model.snapshot.itemId, searchedItemId: searchedId) {
            model.seekText(toCharOffset: match.playbackOffset)
        }
        dismiss()
    }
}

private struct FindInTextRow: View {
    let match: ItemTextSearch.Match

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let heading = FindInTextPresentation.heading(for: match) {
                Text(heading).font(.footnote.weight(.semibold)).foregroundStyle(AppColors.secondaryText).lineLimit(1)
            }
            if let note = match.notReadAloudDescription {
                Text(note).font(.footnote).foregroundStyle(AppColors.warningText)
            }
            excerpt.lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var excerpt: Text {
        let runs = FindInTextPresentation.excerptRuns(for: match)
        return Text(runs.before) + Text(runs.match).bold() + Text(runs.after)
    }
}

/// Runs the matcher off the main thread so a long paper never stalls typing.
@MainActor
final class FindInTextViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var result = ItemTextSearch.Result(matches: [], hasMore: false)
    private var text = ""
    private var chapters: [Chapter] = []
    private var skipped: [ItemTextSearch.SkippedSpan] = []
    private var searchTask: Task<Void, Never>?

    func load(text: String, chapters: [Chapter], itemId: String, store: SQLiteSessionStore?) {
        self.text = text
        self.chapters = chapters
        skipped = []
        guard let store else { return }
        Task { [weak self] in
            let spans = await Task.detached(priority: .userInitiated) { () -> [ItemTextSearch.SkippedSpan] in
                guard let document = try? store.loadStructuredDocument(itemId: itemId), document.text == text else { return [] }
                return ItemTextSearch.SkippedSpan.spans(in: document)
            }.value
            guard let self else { return }
            self.skipped = spans
            self.run()
        }
    }

    func run() {
        searchTask?.cancel()
        let (query, text, chapters, skipped) = (query, text, chapters, skipped)
        searchTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                ItemTextSearch.search(query, in: text, chapters: chapters, skipped: skipped)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.result = found
        }
    }
}
