import Foundation

/// What the Now tab's scene shows and whether it follows the playhead (#4453): the whole-scene index
/// (`PlaybackLivePassage.Index`) and the follow rules (`PlaybackSceneFollow`) put together, so the view only draws.
///
/// The scene on screen is the playing one while following. When the listener has scrolled away and playback reaches the
/// next scene, the scene they are reading stays, with nothing lit, and `nowInTitle` names where playback is. It never
/// moves audio and owns no playback state: the view calls `move` with the source offset playback is at.
public struct PlaybackNowSceneState: Sendable {
    private var index: PlaybackLivePassage.Index
    private let chapters: [Chapter]
    private let textLength: Int
    private var shownIsPlaying = true

    public private(set) var follow = PlaybackSceneFollow()
    /// The scene on screen. Its rows are the same value until the chapter or its Margins change.
    public private(set) var shownScene: PlaybackLivePassage.Scene = .empty
    /// The lit sentence's index in `shownScene`; nil when the scene on screen is not the playing one, or nothing plays.
    public private(set) var litSentence: Int?
    /// Bumped whenever `shownScene` is replaced, so a view can tell a new scene from a moved light without comparing rows.
    public private(set) var sceneRevision = 0
    /// What the list draws for `shownScene`: its sentences, with a card before the sentence that holds each table's or
    /// figure's caption (#4588). Built whenever the scene or the cards change, never on a tick, so it is the same value
    /// for as long as `sceneRevision` is.
    public private(set) var shownItems: [PlaybackLivePassage.SceneItem] = []
    /// For each card in `shownItems`, the start of the sentence it stands before.
    public private(set) var clipHoldStarts: [Int: Int] = [:]
    private var clipAnchors: [PDFClipAnchor] = []
    private var savedClipIds: Set<String> = []
    /// A spoken note's scene (#4780): its own sentences, its own end line, and its Margins as rows.
    private let isNote: Bool
    private var noteMargins: [SpokenNoteNowPassage.MarginItem] = []
    /// Each Margin row's id, handed out the first time the Margin is seen, so adding an earlier Margin never renumbers
    /// the rows after it.
    private var marginRowIds: [String: Int] = [:]
    private var nextMarginRowId = -1_000_000

    /// - Parameters:
    ///   - sentenceStarts: each sentence's start, when the source knows its own sentences (a spoken note); nil splits the
    ///     text at its stops.
    ///   - isNote: a spoken note's scene: "End of the note" after its last sentence.
    public init(text: String, chapters: [Chapter] = [], sentenceStarts: [Int]? = nil, isNote: Bool = false) {
        index = PlaybackLivePassage.Index(text: text, chapters: chapters, sentenceStarts: sentenceStarts)
        self.chapters = chapters
        textLength = text.count
        self.isNote = isNote
    }

    /// The Character count of the text, for building Margins' offsets.
    public var characterCount: Int { index.characterCount }

    public var isEmpty: Bool { shownScene.sentences.isEmpty }

    /// The lit sentence's id (its first Character offset), for scrolling to it.
    public var litSentenceID: Int? {
        guard let litSentence, shownScene.sentences.indices.contains(litSentence) else { return nil }
        return shownScene.sentences[litSentence].id
    }

    /// Where playback is, whichever scene is on screen: the scene to return to and its lit sentence's id.
    public var playingSentenceID: Int? {
        guard let sentence = index.currentSentence, index.scene.sentences.indices.contains(sentence) else { return nil }
        return index.scene.sentences[sentence].id
    }

    /// The playing scene's title, when it is not the scene on screen: the button's second line, "Now in: <title>".
    public var nowInTitle: String? { follow.nowInTitle }

    /// Whether playback is in another scene than the one on screen, with or without a title to name it.
    public var isReadingAnotherScene: Bool { !shownIsPlaying }

    public var offersBackToPlaying: Bool { follow.offersBackToPlaying }

    /// The line after the last sentence of the scene on screen. Not tappable.
    public struct EndLine: Equatable, Sendable {
        public let heading: String
        public let next: String?
    }

    public var endLine: EndLine {
        guard !chapters.isEmpty else { return EndLine(heading: isNote ? "End of the note" : "End of the text", next: nil) }
        let position = chapters.firstIndex { max(0, min($0.startChar, textLength)) == shownScene.chapterStart }
        if let position, chapters.indices.contains(position + 1) {
            return EndLine(heading: "End of this scene", next: chapters[position + 1].title)
        }
        return EndLine(heading: "End of the last scene", next: nil)
    }

    /// Playback is at `offset`. Returns whether the scene on screen or its lit sentence changed.
    ///
    /// Call it once per change of sentence, never on a slower sample: any move that is not the same sentence, the next
    /// one or a later scene's first reads as a jump and starts following again. Pass `byListenerControl: true` for a
    /// move the listener asked for (a seek, Skim, a chapter jump, Rewind, "Play this moment", a Margin moment).
    @discardableResult
    public mutating func move(offset: Int, margins: [PlaybackLivePassage.Margin] = [], byListenerControl: Bool = false) -> Bool {
        let before = (sceneRevision, litSentence, follow)
        let change = index.updateScene(offset: offset, margins: margins)
        // A chapter with no sentence has no playhead to follow.
        if let sentence = index.currentSentence {
            let playhead = PlaybackSceneFollow.Playhead(
                chapterStart: index.scene.chapterStart, chapterTitle: index.scene.chapterTitle, sentence: sentence)
            follow.playheadMoved(to: playhead, byListenerControl: byListenerControl)
        }
        syncShown(change: change)
        return before.0 != sceneRevision || before.1 != litSentence || before.2 != follow
    }

    /// The Back to playing button, or a jump the listener chose elsewhere (a Margin moment): the playing scene, following.
    public mutating func backToPlaying() {
        follow.backToPlayingTapped()
        syncShown(change: .scene)
    }

    public mutating func listenerScrolled() { follow.listenerScrolled() }

    /// The tables and figures of a PDF that have a picture to show, found off the main actor when Now opened. Cards
    /// appear in the scene on screen at once, and the revision moves so the view can tell.
    public mutating func setClips(anchors: [PDFClipAnchor], saved: Set<String>) {
        guard anchors != clipAnchors || saved != savedClipIds else { return }
        clipAnchors = anchors
        savedClipIds = saved
        rebuildItems()
        sceneRevision += 1
    }

    /// A spoken note's Margins, as rows after their sentences (`SpokenNoteNowPassage.Words.marginItems`). Only a change
    /// rebuilds the rows, and the revision moves so the view can tell.
    public mutating func setNoteMargins(_ items: [SpokenNoteNowPassage.MarginItem]) {
        guard items != noteMargins else { return }
        noteMargins = items
        for item in items where marginRowIds[item.key] == nil {
            marginRowIds[item.key] = nextMarginRowId
            nextMarginRowId -= 1
        }
        rebuildItems()
        sceneRevision += 1
    }

    private mutating func rebuildItems() {
        if !clipAnchors.isEmpty, !savedClipIds.isEmpty {
            let placed = PlaybackLivePassage.ClipPlacement.items(scene: shownScene, anchors: clipAnchors, saved: savedClipIds)
            shownItems = placed.items
            clipHoldStarts = placed.holdStarts
        } else {
            shownItems = shownScene.sentences.map { .sentence($0) }
            clipHoldStarts = [:]
        }
        guard !noteMargins.isEmpty else { return }
        var after: [Int: [PlaybackLivePassage.SceneItem]] = [:]
        for item in noteMargins {
            guard let id = marginRowIds[item.key] else { continue }
            after[item.afterRowId, default: []].append(.margin(item, id: id))
        }
        var items: [PlaybackLivePassage.SceneItem] = []
        items.reserveCapacity(shownItems.count + noteMargins.count)
        for item in shownItems {
            items.append(item)
            if case .sentence(let sentence) = item, let margins = after[sentence.id] { items.append(contentsOf: margins) }
        }
        shownItems = items
    }

    public mutating func scrollCameToRest(litSentenceIsVisible: Bool) {
        follow.scrollCameToRest(litSentenceIsVisible: litSentenceIsVisible)
    }

    private mutating func syncShown(change: PlaybackLivePassage.Index.SceneChange) {
        let playing = index.scene
        let onPlayingScene = follow.shownChapterStart == nil || follow.shownChapterStart == playing.chapterStart
        guard onPlayingScene else {
            // Reading an older scene while playback has gone on: it stays, with nothing lit.
            shownIsPlaying = false
            litSentence = nil
            return
        }
        if change == .scene || !shownIsPlaying {
            shownScene = playing
            rebuildItems()
            sceneRevision += 1
        }
        shownIsPlaying = true
        litSentence = index.currentSentence
    }
}
