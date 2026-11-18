import SwiftUI
import SessionKit

/// What the Now tab's scene is doing, shared by the playback screen (which sees the scroll) and the passage (which
/// draws the scene): the scene state, whether the header is on screen, and which sentences are (#4453).
///
/// It follows the playhead and never moves audio. All of its rules are `PlaybackNowSceneState`'s, which is host-tested.
@MainActor
final class NowSceneController: ObservableObject {
    @Published private(set) var state: PlaybackNowSceneState?
    /// Whether the Now header, with the Library arrow in it, is on screen. Following scrolls it away.
    @Published var headerIsVisible = true
    /// The ids (first Character offsets) of the sentences on screen. Not published: a scroll changes it constantly, and
    /// only `playingIsAbove` is drawn.
    private(set) var visibleSentenceIDs: Set<Int> = []
    /// Which way the playing sentence is from what is on screen, for the Back to playing arrow.
    @Published private(set) var playingIsAbove = false
    /// Bumped when the view should scroll to the lit sentence: Back to playing, and a jump the listener chose.
    @Published private(set) var scrollToLitRequest = 0

    func reset(text: String, chapters: [Chapter]) {
        state = PlaybackNowSceneState(text: text, chapters: chapters)
    }

    func move(offset: Int, margins: [PlaybackLivePassage.Margin], byListenerControl: Bool = false) {
        guard var next = state else { return }
        guard next.move(offset: offset, margins: margins, byListenerControl: byListenerControl) else { return }
        state = next
    }

    func listenerScrolled() {
        guard var next = state, next.follow.isFollowing else { return }
        next.listenerScrolled()
        state = next
    }

    /// A scroll came to rest: following starts again when the lit sentence is on screen.
    func scrollCameToRest() {
        guard var next = state, !next.follow.isFollowing else { return }
        let lit = next.litSentenceID.map { visibleSentenceIDs.contains($0) } ?? false
        next.scrollCameToRest(litSentenceIsVisible: lit)
        state = next
    }

    func backToPlaying() {
        guard var next = state else { return }
        next.backToPlaying()
        state = next
        scrollToLitRequest &+= 1
    }

    func sentencesOnScreen(_ ids: [Int]) {
        visibleSentenceIDs = Set(ids)
        guard let state, let playing = state.playingSentenceID, !state.isReadingAnotherScene,
              let first = visibleSentenceIDs.min() else {
            if playingIsAbove { playingIsAbove = false }
            return
        }
        let above = playing < first
        if above != playingIsAbove { playingIsAbove = above }
    }
}

/// The whole scene of the item's retained source text, scrollable, with the playing sentence lit (#4453).
///
/// It sits in the Now pane's page scroll view. While the scene follows, the lit sentence is kept about a third of the way
/// down; a scroll by the listener stops that and Back to playing (drawn by the playback screen) brings it back. Scrolling
/// never moves playback. The rows are lazy and equatable, so a long scene costs nothing per tick.
struct PlaybackLivePassageView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var scene: NowSceneController
    /// The page scroll view's proxy, from the reader that wraps it: a proxy scrolls only the scroll views inside its own reader.
    let proxy: ScrollViewProxy
    let openReader: (Int) -> Void
    @State private var sourceIndex = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: ""))
    @State private var sourceVersion = 0
    @State private var margins: [PlaybackLivePassage.Margin] = []
    @State private var lastOffset: Int?
    @State private var playbackTick = 0 // bumped by each progress tick: the current sentence follows the source offset (#2074)
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var focusedSentence: Int?

    private struct Input: Equatable {
        let itemID: String
        let text: String
        let chapters: [Chapter]
    }
    private var input: Input {
        Input(itemID: model.selectedItem.id, text: model.selectedItem.text, chapters: model.selectedItem.chapters)
    }
    private var sourceOffset: Int? {
        PlaybackLivePassage.sourceOffset(snapshot: model.snapshot, itemID: model.selectedItem.id,
                                         isNativeAudio: model.selectedItem.isNativeAudio,
                                         textLength: scene.state?.characterCount ?? 0)
    }
    /// Shown while this item plays its own source, and while a Margin or summary plays on it (the scene stays, with
    /// its last sentence lit). Hidden for another item or before anything starts, as before.
    private var isShowing: Bool {
        guard let state = scene.state, !state.isEmpty, model.snapshot.itemId == model.selectedItem.id else { return false }
        return sourceOffset != nil || state.litSentence != nil
    }
    private static let litAnchor = UnitPoint(x: 0.5, y: 0.33)

    var body: some View {
        let _ = playbackTick
        return VStack(spacing: 0) {
                if isShowing, let state = scene.state {
                    NowSceneList(
                        scene: state.shownScene, revision: state.sceneRevision, lit: state.litSentence,
                        sourceVersion: sourceVersion, sourceIndex: sourceIndex, endLine: state.endLine,
                        focus: $focusedSentence, openReader: openCurrentSentence
                    )
                    .equatable()
                    // Room under the last row for the Back to playing button, so it never covers it.
                    .padding(.bottom, state.offersBackToPlaying ? 96 : 0)
                }
            }
            .onAppear {
                rebuild()
                // Opening Now always starts with following on, at the lit sentence, without a scroll animation, once
                // its rows are laid out.
                Task { @MainActor in scrollToLit(animated: false) }
            }
            .onChange(of: input) { _, _ in rebuild() }
            .onChange(of: model.selectedItem.timelineSource) { _, value in
                sourceIndex = PlaybackLivePassage.SourceIndex(value)
                sourceVersion &+= 1
            }
            .onChange(of: model.marginRows) { _, _ in updateMargins() }
            .onChange(of: model.sharedMarginRows) { _, _ in updateMargins() }
            .onChange(of: sourceOffset) { _, _ in follow() }
            .onChange(of: scene.state?.litSentenceID) { _, _ in
                guard let state = scene.state, state.follow.scrollsOnItsOwn(assistiveTechnologyRunning: voiceOverEnabled) else { return }
                scrollToLit(animated: true)
            }
            .onChange(of: scene.scrollToLitRequest) { _, _ in
                // The scene is replaced in this update; scroll once its rows are in place.
                Task { @MainActor in
                    scrollToLit(animated: true)
                    if voiceOverEnabled { focusedSentence = scene.state?.litSentenceID }
                }
            }
            .onChange(of: scene.state?.shownScene.chapterStart) { old, new in
                guard voiceOverEnabled, old != nil, old != new, let title = scene.state?.shownScene.chapterTitle else { return }
                AccessibilityNotification.Announcement("Now in \(title)").post()
            }
            .onChange(of: model.showNowRequests) { _, _ in scene.backToPlaying() }
            .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    private func rebuild() {
        lastOffset = nil
        scene.reset(text: input.text, chapters: input.chapters)
        sourceIndex = PlaybackLivePassage.SourceIndex(model.selectedItem.timelineSource)
        sourceVersion &+= 1
        updateMargins()
    }

    private func updateMargins() {
        let length = scene.state?.characterCount ?? 0
        margins = model.marginRows.compactMap {
            PlaybackLivePassage.Margin(own: $0.interjection, itemID: input.itemID, textLength: length)
        } + model.sharedMarginRows.compactMap {
            PlaybackLivePassage.Margin(shared: $0.interjection, layer: $0.layer, itemID: input.itemID, textLength: length)
        }
        follow()
    }

    /// Moves the scene to where playback is. Called when the source offset changes, which is once per sentence.
    private func follow() {
        guard let offset = sourceOffset else {
            // A Margin or summary plays: the scene stays as it was. A change of Margins still needs the last offset.
            if let lastOffset { scene.move(offset: lastOffset, margins: margins) }
            return
        }
        lastOffset = offset
        // Playback going on moves the light only while playing. A move while paused or starting is the listener's (a seek,
        // Skim, Rewind), even one sentence on, and starts following again.
        scene.move(offset: offset, margins: margins, byListenerControl: model.snapshot.status != .playing)
    }

    /// The lit sentence about a third of the way down the visible area. Near the start of a scene the scroll view's own
    /// top edge stops it, so the header stays in sight.
    private func scrollToLit(animated: Bool) {
        guard let id = scene.state?.litSentenceID else { return }
        if animated {
            withMotion { proxy.scrollTo(id, anchor: Self.litAnchor) }
        } else {
            proxy.scrollTo(id, anchor: Self.litAnchor)
        }
    }

    /// Tapping a sentence opens the reader at the playing sentence, as it always has.
    private func openCurrentSentence() {
        guard let offset = sourceOffset ?? lastOffset else { return }
        openReader(offset)
    }
}

/// The scene's rows. Equatable on what changes what is drawn (the scene's revision, the lit sentence, the source's
/// fragments), so a playback tick that changes none of them draws nothing, however long the scene is.
private struct NowSceneList: View, Equatable {
    let scene: PlaybackLivePassage.Scene
    let revision: Int
    let lit: Int?
    let sourceVersion: Int
    let sourceIndex: PlaybackLivePassage.SourceIndex
    let endLine: PlaybackNowSceneState.EndLine
    let focus: AccessibilityFocusState<Int?>.Binding
    let openReader: () -> Void

    private var litID: Int? {
        guard let lit, scene.sentences.indices.contains(lit) else { return nil }
        return scene.sentences[lit].id
    }

    nonisolated static func == (lhs: NowSceneList, rhs: NowSceneList) -> Bool {
        lhs.revision == rhs.revision && lhs.lit == rhs.lit && lhs.sourceVersion == rhs.sourceVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(scene.sentences) { sentence in
                    NowSceneRow(
                        sentence: sentence, fragments: sourceIndex.fragments(for: sentence), isLit: sentence.id == litID,
                        focus: focus, openReader: openReader
                    )
                }
            }
            .scrollTargetLayout()
            VStack(alignment: .leading, spacing: 2) {
                Text(endLine.heading).font(.footnote.weight(.semibold))
                if let next = endLine.next { Text("Next: \(next)").font(.footnote) }
            }
            .foregroundStyle(AppColors.watchSecondary)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("playback.now.passage.end")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.now.passage")
    }
}

#if DEBUG
/// How many row bodies have run, and which sentences have had one, so an app-hosted test can show a long scene
/// realizes only the rows near the screen (distinct sentences: a redraw of the same row is not a new row) and a tick
/// that keeps the same sentence draws none (body count) (#4453).
@MainActor
enum NowSceneRowCounter {
    private(set) static var bodies = 0
    private(set) static var sentences: Set<Int> = []
    static func count(sentence: Int) -> Int {
        bodies += 1
        sentences.insert(sentence)
        return bodies
    }
    static func reset() { sentences = [] }
}
#endif

private struct NowSceneRow: View {
    let sentence: PlaybackLivePassage.Sentence
    let fragments: [PlaybackLivePassage.Fragment]
    let isLit: Bool
    let focus: AccessibilityFocusState<Int?>.Binding
    let openReader: () -> Void

    var body: some View {
        #if DEBUG
        let _ = NowSceneRowCounter.count(sentence: sentence.id)
        #endif
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 5) {
                ForEach(sentence.diamonds) { diamond in
                    Image(systemName: diamond.origin == .own ? "diamond.fill" : "diamond")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(diamond.origin == .own ? AppColors.listeningAccent : Color.blue)
                        .accessibilityLabel(diamond.origin == .own ? "Your Margin" : "Shared Margin")
                        .accessibilityIdentifier("playback.now.passage.margin.\(diamond.id)")
                }
            }
            .frame(width: 18)
            .padding(.top, 12)
            Button(action: openReader) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fragments) { fragment in
                        if let label = fragment.label {
                            Text(label).font(.caption.weight(.semibold))
                        }
                        Text(fragment.text)
                            .font(fragment.role == .table ? .body.monospaced() : .body)
                            .fontWeight(fragment.role == .heading || fragment.role == .title ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(isLit ? Color.white : AppColors.watchSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(isLit ? AppColors.listeningAccent.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .leading) {
                    if isLit {
                        Capsule().fill(AppColors.listeningAccent).frame(width: 3).padding(.vertical, 5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sentence.text)
            .accessibilityHint("Open the full source at the current sentence")
            .accessibilityValue(isLit ? "Current sentence" : "")
            .accessibilityAddTraits(isLit ? .isSelected : [])
            .accessibilityFocused(focus, equals: sentence.id)
            .accessibilityIdentifier("playback.now.passage.sentence.\(sentence.id)")
        }
    }
}

/// The floating button that brings the playing sentence back after the listener has read elsewhere (#4453). A control,
/// not content, so it takes the system's glass. It sits above the dock; the passage leaves room so it never covers a row.
struct NowBackToPlayingButton: View {
    @ObservedObject var scene: NowSceneController

    var body: some View {
        if let state = scene.state, state.offersBackToPlaying, state.playingSentenceID != nil {
            let title = state.nowInTitle
            Button {
                scene.backToPlaying()
            } label: {
                VStack(spacing: 2) {
                    Label("Back to playing", systemImage: scene.playingIsAbove ? "arrow.up" : "arrow.down")
                        .font(.subheadline.weight(.semibold))
                    if let title {
                        Text("Now in: \(title)").font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
            }
            .buttonStyle(.glass)
            .padding(.bottom, 12)
            .accessibilityLabel(title.map { "Back to the playing sentence, now in \($0)" } ?? "Back to the playing sentence")
            .accessibilityHint("Scrolls to the sentence being read. Playback doesn't change.")
            .accessibilityIdentifier("playback.now.passage.back")
        }
    }
}
