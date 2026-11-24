import Combine
import SessionKit
import SessionKitPersistence
import SwiftUI
import UIKit

/// What the Now tab's scene is doing, shared by the playback screen (which sees the scroll) and the passage (which
/// draws the scene): the scene state, whether the header is on screen, and which sentences are (#4453).
///
/// It follows the playhead and never moves audio. All of its rules are `PlaybackNowSceneState`'s, which is host-tested.
@MainActor
final class NowSceneController: ObservableObject {
    @Published private(set) var state: PlaybackNowSceneState?
    /// Whether the Now header, with the Library arrow in it, is on screen. Following scrolls it away. Two thresholds
    /// decide it (`NowHeaderVisibility`), so the toolbar arrow it brings can't move the header back and forth (#4739).
    @Published private(set) var headerIsVisible = true
    private var header = NowHeaderVisibility()

    /// Whether at least `NowHeaderVisibility.goneBelow` of the header is on screen.
    func headerReachedGoneThreshold(_ visible: Bool) {
        header.reachedGoneThreshold(visible)
        publishHeader()
    }

    /// Whether at least `NowHeaderVisibility.backAt` of the header is on screen.
    func headerReachedBackThreshold(_ visible: Bool) {
        header.reachedBackThreshold(visible)
        publishHeader()
    }

    /// Published only on a change, so a threshold report that changes nothing redraws nothing.
    private func publishHeader() {
        if headerIsVisible != header.isVisible { headerIsVisible = header.isVisible }
    }
    /// Whether the scene lights its playing row: false on a spoken note that is not the one playing, or before its first
    /// worded sentence (#4780). Articles always light. Back to playing shows only while it is true.
    @Published var showsLit = true
    /// The ids (first Character offsets) of the sentences on screen. Not published: a scroll changes it constantly, and
    /// only `playingIsAbove` is drawn.
    private(set) var visibleSentenceIDs: Set<Int> = []
    /// Which way the playing sentence is from what is on screen, for the Back to playing arrow.
    @Published private(set) var playingIsAbove = false
    /// Bumped when the view should scroll to the lit sentence: Back to playing, and a jump the listener chose.
    @Published private(set) var scrollToLitRequest = 0

    /// The tables' and figures' cards of a PDF, with where their pictures are read from and the room they have (#4588).
    /// `clipsVersion` moves whenever the cards or their folder change, so the list can tell without comparing them.
    private(set) var cards = NowClipCards.none
    @Published private(set) var clipsVersion = 0
    /// The height of the text area the cards and the hold are sized against. Published so a rotation resizes the cards;
    /// guarded, so a scroll never redraws the list.
    @Published private(set) var visibleHeight: Double = 0
    /// The width of the scene list, for sizing cards and estimating how tall a sentence is. Not published: it only
    /// changes with the layout, and the cards read it when they are drawn.
    private(set) var listWidth: Double = 0
    /// Bumped when a hold that did not keep the lit sentence on screen is dropped, so the view scrolls the usual way.
    @Published private(set) var holdDroppedRequest = 0
    /// The cards whose hold did not keep the lit sentence on screen. They hold no more, so a wrong height estimate costs
    /// one correction, not one for every sentence after (`ClipHold.stillDropped`).
    private var droppedHolds: Set<Int> = []

    func reset(text: String, chapters: [Chapter], sentenceStarts: [Int]? = nil, isNote: Bool = false) {
        state = PlaybackNowSceneState(text: text, chapters: chapters, sentenceStarts: sentenceStarts, isNote: isNote)
        showsLit = true
        // The cards belong to the text that is gone; the view finds them again for the new one.
        cards = NowClipCards(source: .none, anchors: [], listWidth: listWidth, visibleHeight: visibleHeight)
        droppedHolds = []
        clipsVersion &+= 1
    }

    /// The cards the scene shows, found off the main actor. An empty list clears them.
    func setClips(anchors: [PDFClipAnchor], saved: Set<String>, source: TimelineClipSource) {
        guard var next = state else { return }
        let source = saved.isEmpty ? TimelineClipSource.none : source
        // The same cards from the same folder: nothing to redraw.
        guard anchors != cards.anchors || source != cards.source else { return }
        next.setClips(anchors: anchors, saved: saved)
        state = next
        droppedHolds = []
        cards = NowClipCards(source: source, anchors: anchors, listWidth: listWidth, visibleHeight: visibleHeight)
        clipsVersion &+= 1
    }

    func setVisibleHeight(_ height: Double) {
        guard abs(height - visibleHeight) >= 1 else { return }
        visibleHeight = height
        cards.visibleHeight = height
    }

    func setListWidth(_ width: Double) {
        guard abs(width - listWidth) >= 1 else { return }
        listWidth = width
        cards.listWidth = width
        clipsVersion &+= 1
    }

    /// Where following scrolls for the lit sentence: a card whose caption is being read, held at the top while what is
    /// read fits under it, or the sentence itself (#4588).
    func scrollTarget(sentences: (PlaybackLivePassage.Sentence) -> [PlaybackLivePassage.Fragment]) -> PlaybackLivePassage.ScrollTarget {
        guard let state, let lit = state.litSentence, let litID = state.litSentenceID, !state.clipHoldStarts.isEmpty,
              visibleHeight > 0, listWidth > 0 else { return .sentence }
        let scene = state.shownScene
        droppedHolds = PlaybackLivePassage.ClipHold.stillDropped(
            droppedHolds, holdStarts: state.clipHoldStarts, litStart: scene.sentences[lit].start)
        let body = UIFont.preferredFont(forTextStyle: .body)
        let metrics = PlaybackLivePassage.ClipHold.Metrics(
            // The text column: the list's width less the diamond gutter (18), the spacing (10) and the row's own padding (20).
            columnWidth: listWidth - 18 - 10 - 20, visibleHeight: visibleHeight,
            bodyPointSize: Double(body.pointSize), lineHeight: Double(body.lineHeight))
        // The cards in the order they stand: ids run -1, -2, ... in the order of the anchor list.
        let clips = state.clipHoldStarts.keys.sorted(by: >).compactMap { id -> (id: Int, holdStart: Int, height: Double)? in
            guard let start = state.clipHoldStarts[id], let anchor = cards.anchor(forCard: id) else { return nil }
            return (id, start, cards.rowHeight(for: anchor))
        }
        let target = PlaybackLivePassage.ClipHold.target(
            scene: scene, lit: lit, clips: clips, visibleHeight: visibleHeight, dropped: droppedHolds,
            sentenceHeight: { index in
                PlaybackLivePassage.ClipHold.rowHeight(fragments: sentences(scene.sentences[index]), metrics: metrics)
            })
        if case .clip(let card) = target { checkHoldKeptLitSentence(litID, card: card) }
        return target
    }

    /// A held card must never leave the sentence being read out of sight (the height estimate can be wrong). Once the
    /// scroll has settled, a hold that left the lit sentence off screen is dropped and the view scrolls the usual way.
    /// Judged after a pause, not on the first report of what is on screen: that one can come mid-scroll, and a scroll
    /// that moves nothing (the card already at the top) reports nothing at all.
    private func checkHoldKeptLitSentence(_ litID: Int, card: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, let state = self.state, state.follow.isFollowing,
                  state.litSentenceID == litID, !self.visibleSentenceIDs.contains(litID) else { return }
            self.droppedHolds.insert(card)
            self.holdDroppedRequest &+= 1
        }
    }

    func move(offset: Int, margins: [PlaybackLivePassage.Margin], byListenerControl: Bool = false) {
        guard var next = state else { return }
        guard next.move(offset: offset, margins: margins, byListenerControl: byListenerControl) else { return }
        state = next
    }

    /// A spoken note's Margins, as rows after their sentences (#4780).
    func setNoteMargins(_ items: [SpokenNoteNowPassage.MarginItem]) {
        guard var next = state else { return }
        next.setNoteMargins(items)
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
        // Cards have negative ids and are not sentences: one on screen never counts as the lit sentence being visible.
        visibleSentenceIDs = Set(ids.filter { $0 >= 0 })
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
    /// A spoken note's own words (#4780): when set, the scene is the note's sentences, a tap plays from a sentence, and
    /// Margins are rows. Nil is an article or PDF, as before.
    var noteWords: SpokenNoteNowPassage.Words? = nil
    var noteRevision = 0
    /// Opens a Margin's detail sheet, by the Margin's id (a note's Margin row).
    var openMargin: (String) -> Void = { _ in }
    @State private var sourceIndex = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: ""))
    @State private var sourceVersion = 0
    /// The item's footnote markers as shown (#5109), scanned once per text.
    @State private var footnotes = FootnoteDisplayText.none
    @State private var margins: [PlaybackLivePassage.Margin] = []
    @State private var lastOffset: Int?
    @State private var playbackTick = 0 // bumped by each progress tick: the current sentence follows the source offset (#2074)
    /// Bumped when the item's clips were saved (a PDF just imported, or imported again) and by each rebuild of the scene,
    /// so the cards are found again for the scene that now stands (#4588).
    @State private var clipsSaved = 0
    @State private var rebuilds = 0
    @State private var selectedClip: TimelineClipSelection?
    /// The input the scene was last built for by this view. A full-screen cover takes the view under it off screen and
    /// back, so `onAppear` also runs when the picture viewer closes; the scene is rebuilt only for an input it has not
    /// been built for, never to return from the viewer, where it would lose the listener's place and the cards.
    @State private var builtInput: Input?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AccessibilityFocusState private var focusedSentence: Int?
    /// A spoken note's following (#4780). A reference, not observed: it changes on every clock tick and draws nothing.
    @State private var noteFollow = NoteFollow()
    @State private var noteMarginItems: [SpokenNoteNowPassage.MarginItem] = []
    @State private var noteMarginPreviews: [String] = []
    /// Each Margin row's preview text, by Margin id, so a row draws without searching the model's Margins.
    @State private var noteMarginPreviewByID: [String: String] = [:]
    @State private var marginRevision = 0

    /// The row offset last fed to the scene, the clock's last media time, and whether the next change is the listener's
    /// own (a tap on a sentence).
    private final class NoteFollow {
        var offset: Int?
        var lastTickMs: Int?
        var pendingListenerMove = false
    }

    private struct Input: Equatable {
        let itemID: String
        let text: String
        let chapters: [Chapter]
        let noteRevision: Int
    }
    private var input: Input {
        // A note's scene is its own words: an item refresh (a seek refreshes the item) never rebuilds it.
        if noteWords != nil { return Input(itemID: model.selectedItem.id, text: "", chapters: [], noteRevision: noteRevision) }
        return Input(itemID: model.selectedItem.id, text: model.selectedItem.text, chapters: model.selectedItem.chapters,
                     noteRevision: 0)
    }
    private var isNoteSessionItem: Bool { model.snapshot.itemId == model.selectedItem.id }
    /// The note is the session's item and its own audio is what plays (not a Margin on it).
    private var noteSourceIsPlaying: Bool {
        isNoteSessionItem && model.snapshot.targetType.flatMap(TargetType.init(rawValue:)) == .transcriptBackedMedia
    }
    /// The clock's media time while the note's own audio plays; nil otherwise, which keeps the last row lit.
    private var noteMediaTimeMs: Int? {
        guard noteWords != nil, noteSourceIsPlaying else { return nil }
        return model.playbackClock.position.mediaTimeMs
    }
    private var noteTapState: SpokenNoteNowPassage.RowTap {
        // While a Margin is recorded or written, the listener's place is held: no row moves it.
        if model.recordingNavigationIsLocked { return .inert }
        return SpokenNoteNowPassage.RowTap.rowTap(
            hasActiveSession: model.hasActiveSession, isSessionItem: isNoteSessionItem,
            targetIsSource: model.snapshot.targetType.flatMap(TargetType.init(rawValue:)) == .transcriptBackedMedia,
            phase: model.snapshot.phase, hasAudio: true)
    }
    /// What finding the cards depends on, as counts: this is read on every tick, so it never compares the document.
    private struct ClipsInput: Equatable {
        let itemID: String
        let textLength: Int
        let floats: Int
        let segments: Int
        let saved: Int
        let rebuilds: Int
    }
    private var clipsInput: ClipsInput {
        let source = model.selectedItem.pdfClipSource
        return ClipsInput(itemID: model.selectedItem.id, textLength: model.selectedItem.text.utf8.count,
                          floats: source?.floats.count ?? 0, segments: source?.segments.count ?? 0,
                          saved: clipsSaved, rebuilds: rebuilds)
    }
    private var sourceOffset: Int? {
        // A note's lit row comes from the clock and its own timeline, never the engine's text offset (#4780).
        guard noteWords == nil else { return nil }
        return PlaybackLivePassage.sourceOffset(snapshot: model.snapshot, itemID: model.selectedItem.id,
                                         isNativeAudio: model.selectedItem.isNativeAudio,
                                         textLength: scene.state?.characterCount ?? 0)
    }
    /// Shown while this item plays its own source, and while a Margin or summary plays on it (the scene stays, with
    /// its last sentence lit). Hidden for another item or before anything starts, as before.
    private var isShowing: Bool {
        // A note's words show whenever there are any, lit or not (#4780).
        // Only a scene built for this note: the shared controller may still hold the last item's for one pass.
        if noteWords != nil { return builtInput == input && !(scene.state?.isEmpty ?? true) }
        guard let state = scene.state, !state.isEmpty, model.snapshot.itemId == model.selectedItem.id else { return false }
        return sourceOffset != nil || state.litSentence != nil
    }
    private static let litAnchor = UnitPoint(x: 0.5, y: 0.33)

    /// What a note's scene adds to the list; nil for an article or PDF.
    private var noteList: NowSceneList.Note? {
        noteWords.map { words in
            NowSceneList.Note(
                showsLit: scene.showsLit, tapState: noteTapState, tappableIds: words.rowIdsWithAudio,
                revision: noteRevision, marginRevision: marginRevision, marginPreviews: noteMarginPreviewByID,
                playFrom: playNote(fromRow:), openMargin: openMargin)
        }
    }

    var body: some View {
        let _ = playbackTick
        return VStack(spacing: 0) {
                if isShowing, let state = scene.state {
                    let note = noteList
                    NowSceneList(
                        items: state.shownItems, revision: state.sceneRevision, lit: state.litSentence, litID: state.litSentenceID,
                        sourceVersion: sourceVersion, sourceIndex: sourceIndex, endLine: state.endLine,
                        cards: scene.cards, clipsVersion: scene.clipsVersion, visibleHeight: scene.visibleHeight,
                        focus: $focusedSentence, openReader: openCurrentSentence,
                        openClip: { selectedClip = $0 },
                        note: note, noteDrawKey: note?.drawKey
                    )
                    .equatable()
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { scene.setListWidth($0) }
                    // Room under the last row for the Back to playing button, so it never covers it.
                    .padding(.bottom, state.offersBackToPlaying ? 96 : 0)
                }
            }
            .onAppear {
                // Back from the picture viewer: the scene, the cards and the listener's place are as they were left.
                guard builtInput != input || scene.state == nil else { return }
                rebuild()
                // Opening Now always starts with following on, at the lit sentence, without a scroll animation, once
                // its rows are laid out.
                Task { @MainActor in scrollToLit(animated: false) }
            }
            .onChange(of: input) { _, _ in rebuild() }
            .onChange(of: model.selectedItem.timelineSource) { _, value in
                guard noteWords == nil else { return } // a note's rows are its own words
                sourceIndex = PlaybackLivePassage.SourceIndex(value, footnotes: footnotes)
                sourceVersion &+= 1
            }
            .onChange(of: model.marginRows) { _, _ in updateMargins() }
            .onChange(of: model.sharedMarginRows) { _, _ in updateMargins() }
            .onChange(of: sourceOffset) { _, _ in follow() }
            .onChange(of: noteMediaTimeMs) { _, time in followNote(to: time) }
            .onChange(of: isNoteSessionItem) { _, _ in updateNoteShowsLit() }
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
            .onChange(of: scene.holdDroppedRequest) { _, _ in
                // A held card left the lit sentence off screen: go to the sentence the usual way.
                guard let state = scene.state, state.follow.scrollsOnItsOwn(assistiveTechnologyRunning: voiceOverEnabled) else { return }
                scrollToLit(animated: true)
            }
            // The tables and figures of a PDF with a picture to show. Found off the main actor, and again when the item's
            // clips are saved; until then there are no cards and the scene is its text, as it always was (#4588).
            .task(id: clipsInput) { await findClips() }
            .onReceive(NotificationCenter.default.publisher(for: PDFClipStore.didSaveClipsNotification)
                .receive(on: DispatchQueue.main)) { notice in
                if notice.userInfo?[PDFClipStore.itemIdKey] as? String == input.itemID { clipsSaved &+= 1 }
            }
            .trackedFullScreenCover(item: $selectedClip) { clip in
                TimelineClipViewer(selection: clip)
            }
            .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }

    private func rebuild() {
        lastOffset = nil
        rebuilds &+= 1
        builtInput = input
        if let words = noteWords {
            rebuildNote(words)
            return
        }
        scene.reset(text: input.text, chapters: input.chapters)
        footnotes = FootnoteDisplayText(text: input.text)
        sourceIndex = PlaybackLivePassage.SourceIndex(model.selectedItem.timelineSource, footnotes: footnotes)
        sourceVersion &+= 1
        updateMargins()
    }

    /// A note's scene: its sentences as rows, no footnotes or structure, then lit at the clock's time when the note is
    /// the one playing. Built at its first row so it shows unlit (another item, or before the first worded sentence).
    private func rebuildNote(_ words: SpokenNoteNowPassage.Words) {
        noteFollow.offset = nil
        noteFollow.lastTickMs = nil
        noteFollow.pendingListenerMove = false
        noteMarginItems = []
        noteMarginPreviews = []
        scene.reset(text: words.text, chapters: [], sentenceStarts: words.sentenceStarts, isNote: true)
        footnotes = .none
        sourceIndex = PlaybackLivePassage.SourceIndex(TimelineSourceContent(text: words.text))
        sourceVersion &+= 1
        if let first = words.sentenceStarts.first { scene.move(offset: first, margins: []) }
        updateMargins()
        let time = noteMediaTimeMs
        followNote(to: time)
        updateNoteShowsLit()
    }

    private func updateNoteShowsLit() {
        guard noteWords != nil else { return }
        let lit = isNoteSessionItem && noteFollow.offset != nil
        if scene.showsLit != lit { scene.showsLit = lit }
    }

    /// Moves a note's lit row to the clock's media time. Playback going on feeds every row it passed, so a short sentence
    /// between two ticks is never read as a jump; a seek, a skip, a rewind or a tap is one move by the listener. No time,
    /// or a time before the first worded sentence, changes nothing: the last row stays lit.
    private func followNote(to time: Int?) {
        guard let words = noteWords else { return }
        let previousTick = noteFollow.lastTickMs
        noteFollow.lastTickMs = time
        guard let time, let offset = words.sourceOffset(mediaTimeMs: time), offset != noteFollow.offset else { return }
        let previous = noteFollow.offset
        noteFollow.offset = offset
        defer { updateNoteShowsLit() }
        if noteFollow.pendingListenerMove || previous == nil
            || !SpokenNoteNowPassage.Words.isContinuous(fromMs: previousTick, toMs: time) {
            noteFollow.pendingListenerMove = false
            scene.move(offset: offset, margins: [], byListenerControl: true)
            return
        }
        for crossed in words.rowsCrossed(fromOffset: previous, toOffset: offset) {
            scene.move(offset: crossed, margins: [])
        }
    }

    /// A tap on a note's sentence: play from its start. The next move of the lit row is the listener's own, so following
    /// starts again at the tapped row and Back to playing goes away.
    private func playNote(fromRow id: Int) {
        guard let words = noteWords, noteTapState == .seeks, let row = words.row(id: id), let startMs = row.startMs,
              !model.rejectNavigationOrSessionMutationWhileRecording("play_note_sentence") else { return }
        let moved = MainThreadOperationLabels.shared.scoped("spokenNote.nowJump") { () -> Bool in
            guard model.seekMedia(toMediaTimeMs: startMs) else { return false }
            if !model.snapshot.status.isPlaybackActive { model.resumePlayback() }
            return true
        }
        // Only a seek that happened makes the next move the listener's; a refused one must not later pull a reader back.
        guard moved else { return }
        if row.start == noteFollow.offset {
            scene.backToPlaying()
        } else {
            noteFollow.pendingListenerMove = true
        }
        if voiceOverEnabled { focusedSentence = id }
    }

    private func updateMargins() {
        if let words = noteWords {
            // A note's Margins are rows after their sentences, placed by segment id; no diamonds (#4780).
            let items = words.marginItems(model.marginRows.map(\.interjection), itemId: input.itemID)
            let previews = items.map { item in
                model.marginRows.first { $0.interjection.id == item.marginId }.map { NowSceneMarginRow.previewText($0.interjection) } ?? ""
            }
            if items != noteMarginItems || previews != noteMarginPreviews {
                noteMarginItems = items
                noteMarginPreviews = previews
                noteMarginPreviewByID = Dictionary(zip(items.map(\.marginId), previews), uniquingKeysWith: { first, _ in first })
                marginRevision &+= 1
                scene.setNoteMargins(items)
            }
            return
        }
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
    /// top edge stops it, so the header stays in sight. While a table's or figure's caption is read and what is read still
    /// fits under its card, the card is held at the top instead, with the caption directly under it (#4588).
    private func scrollToLit(animated: Bool) {
        guard let id = scene.state?.litSentenceID else { return }
        let target = scene.scrollTarget { [sourceIndex] in sourceIndex.fragments(for: $0) }
        let (scrollID, anchor): (Int, UnitPoint) = switch target {
        case .sentence: (id, Self.litAnchor)
        case .clip(let cardID): (cardID, .top)
        }
        if animated {
            withMotion { proxy.scrollTo(scrollID, anchor: anchor) }
        } else {
            proxy.scrollTo(scrollID, anchor: anchor)
        }
    }

    /// Finds which of a PDF's tables and figures have a picture on this phone and where each stands in the text. The work
    /// is off the main actor: the anchors are pure CPU over the segment table and the folder is listed once (no clip file
    /// is opened). Nothing is found for an article, a page or a podcast, or a PDF imported before pictures were kept.
    private func findClips() async {
        let itemID = input.itemID
        let text = input.text
        guard let source = model.selectedItem.pdfClipSource, let store = model.pdfClipStore() else {
            scene.setClips(anchors: [], saved: [], source: .none)
            return
        }
        let found = await Task.detached(priority: .utility) {
            (anchors: PDFClipAnchors.make(text: text, source: source), available: store.available(forItem: itemID))
        }.value
        // The listener may have moved to another item, or the text may have been rebuilt, while this ran.
        guard !Task.isCancelled, input.itemID == itemID, input.text == text else { return }
        let saved = Set(found.anchors.map(\.floatId).filter { found.available.contains(floatId: $0) })
        scene.setClips(anchors: found.anchors, saved: saved,
                       source: TimelineClipSource(store: store, itemId: itemID, available: found.available))
        // Cards arriving in a scene that is following re-scroll to where the reading line now is, without animation.
        guard let state = scene.state, state.follow.scrollsOnItsOwn(assistiveTechnologyRunning: voiceOverEnabled) else { return }
        Task { @MainActor in scrollToLit(animated: false) }
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
    /// The scene's sentences with a card before the sentence that holds each caption (`PlaybackNowSceneState.shownItems`).
    let items: [PlaybackLivePassage.SceneItem]
    let revision: Int
    let lit: Int?
    /// The lit sentence's id (`lit` is its index among the sentences; the items hold cards between them).
    let litID: Int?
    let sourceVersion: Int
    let sourceIndex: PlaybackLivePassage.SourceIndex
    let endLine: PlaybackNowSceneState.EndLine
    let cards: NowClipCards
    let clipsVersion: Int
    let visibleHeight: Double
    let focus: AccessibilityFocusState<Int?>.Binding
    let openReader: () -> Void
    let openClip: (TimelineClipSelection) -> Void
    /// A spoken note's scene (#4780); nil for an article or PDF.
    let note: Note?
    /// `note`'s drawing key, kept apart so `==` reads only Sendable values.
    let noteDrawKey: Note.DrawKey?

    /// What a note's scene adds: whether the playing row is lit, what a tap on a row does, and its Margin rows.
    struct Note {
        let showsLit: Bool
        let tapState: SpokenNoteNowPassage.RowTap
        /// The rows that have audio to play from.
        let tappableIds: Set<Int>
        /// The note's words' revision: `tappableIds` changes only with it.
        let revision: Int
        /// Moves when the Margin rows or any of their previews change.
        let marginRevision: Int
        /// Each Margin row's preview text, by Margin id.
        let marginPreviews: [String: String]
        let playFrom: (Int) -> Void
        let openMargin: (String) -> Void

        /// What changes how the rows are drawn; the closures never do.
        struct DrawKey: Equatable, Sendable {
            let showsLit: Bool
            let tapState: SpokenNoteNowPassage.RowTap
            let revision: Int
            let marginRevision: Int
        }
        var drawKey: DrawKey { DrawKey(showsLit: showsLit, tapState: tapState, revision: revision, marginRevision: marginRevision) }
    }

    // The cards' version and the text area's height are what change a card; a tick changes neither, so it draws nothing.
    nonisolated static func == (lhs: NowSceneList, rhs: NowSceneList) -> Bool {
        lhs.revision == rhs.revision && lhs.lit == rhs.lit && lhs.sourceVersion == rhs.sourceVersion
            && lhs.clipsVersion == rhs.clipsVersion && lhs.visibleHeight == rhs.visibleHeight
            && lhs.noteDrawKey == rhs.noteDrawKey
    }

    private var hint: String {
        guard let note else { return "Open the full source at the current sentence" }
        switch note.tapState {
        case .seeks: return "Plays from this sentence."
        case .inertFinished: return "Play the note again to jump to a sentence."
        case .inert: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    switch item {
                    case .sentence(let sentence):
                        if let note {
                            let tappable = note.tapState == .seeks && note.tappableIds.contains(sentence.id)
                            NowSceneRow(
                                sentence: sentence, fragments: sourceIndex.fragments(for: sentence),
                                isLit: note.showsLit && sentence.id == litID, focus: focus,
                                isTappable: tappable, hint: tappable || note.tapState == .inertFinished ? hint : "",
                                onTap: { id in if tappable { note.playFrom(id) } }
                            )
                        } else {
                            NowSceneRow(
                                sentence: sentence, fragments: sourceIndex.fragments(for: sentence), isLit: sentence.id == litID,
                                focus: focus, isTappable: true, hint: hint, onTap: { _ in openReader() }
                            )
                        }
                    case .clip(_, let id):
                        if let anchor = cards.anchor(forCard: id) {
                            NowClipCard(anchor: anchor, cards: cards, open: openClip)
                        }
                    case .margin(let margin, _):
                        if let preview = note?.marginPreviews[margin.marginId] {
                            NowSceneMarginRow(item: margin, preview: preview, open: { note?.openMargin(margin.marginId) })
                        }
                    }
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
    /// False for a note's row that does nothing on a tap: it keeps its look but is not a button (#4780).
    let isTappable: Bool
    let hint: String
    /// Called with the sentence's id: an article opens the reader, a note plays from the sentence.
    let onTap: (Int) -> Void

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
            Button { onTap(sentence.id) } label: {
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
            .accessibilityLabel(fragments.map(\.text).joined())
            .accessibilityHint(hint)
            .accessibilityValue(isLit ? "Current sentence" : "")
            .accessibilityAddTraits(isLit ? .isSelected : [])
            .accessibilityRemoveTraits(isTappable ? [] : .isButton)
            .accessibilityFocused(focus, equals: sentence.id)
            .accessibilityIdentifier("playback.now.passage.sentence.\(sentence.id)")
        }
    }
}

/// One of the listener's Margins on a spoken note, as a one-line row after the sentence it sits on (#4780): the Recent
/// Margins row's look, indented under the text, never lit and never a place following scrolls to. A tap opens it.
private struct NowSceneMarginRow: View {
    let item: SpokenNoteNowPassage.MarginItem
    let preview: String
    let open: () -> Void

    static func previewText(_ note: Interjection) -> String {
        PlaybackMarginPreview.text(displayText: note.displayText, cleanedTranscript: note.cleanedTranscript,
                                   transcript: note.transcript, transcriptionStatus: note.transcriptionStatus,
                                   captureKind: note.captureKind)
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Margin").font(.caption).foregroundStyle(AppColors.watchSecondary)
                Text(preview).font(.body).foregroundStyle(Color.white).lineLimit(1)
            }
            .padding(.leading, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(AppColors.captureBackground).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Under the text, not the gutter: the gutter (18) and the spacing after it (10).
        .padding(.leading, PlaybackLivePassage.ClipCardLayout.leadingInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your Margin: \(preview)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("playback.now.passage.margin.\(item.key)")
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
