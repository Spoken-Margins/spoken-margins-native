@testable import SessionKit
import XCTest

/// Where cards stand among the Now tab's sentences, and when following holds one at the top (#4588).
final class PlaybackNowClipsTests: XCTestCase {
    private func anchor(_ id: String, at offset: Int, kind: StructuredDocument.Float.Kind = .table) -> PDFClipAnchor {
        PDFClipAnchor(floatId: id, kind: kind, numberLabel: "Table", pageNumber: 1, anchor: offset, aspect: 1.5,
                      hasCaption: true, pageIndex: 0, top: 0.5)
    }

    private let text = "First one here. Second one here. Table 1. Caption words. Fourth one here.   "

    private func scene(text: String? = nil, chapters: [Chapter] = [], at offset: Int = 0) -> PlaybackLivePassage.Scene {
        var index = PlaybackLivePassage.Index(text: text ?? self.text, chapters: chapters)
        index.updateScene(offset: offset)
        return index.scene
    }

    private func offset(of phrase: String) -> Int { (text as NSString).range(of: phrase).location }

    // MARK: Placement

    func testACardStandsBeforeTheSentenceThatHoldsItsAnchor() {
        let scene = scene()
        let placed = PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [anchor("a", at: offset(of: "Table 1"))], saved: ["a"])
        let shape = placed.items.map { item -> String in
            switch item {
            case .sentence(let sentence): sentence.text
            case .clip(let floatId, let id): "clip \(floatId) \(id)"
            }
        }
        XCTAssertEqual(shape, ["First one here.", "Second one here.", "clip a -1", "Table 1.", "Caption words.", "Fourth one here."])
        XCTAssertEqual(placed.holdStarts[-1], offset(of: "Table 1"))
    }

    func testAnAnchorMidSentenceStandsBeforeThatSentence() {
        let scene = scene()
        let placed = PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [anchor("a", at: offset(of: "Second") + 4)], saved: ["a"])
        XCTAssertEqual(placed.clipIds, [-1])
        XCTAssertEqual(placed.holdStarts[-1], offset(of: "Second"))
        XCTAssertEqual(placed.items[1].id, -1)
    }

    func testAnAnchorInTheSpaceBetweenSentencesStandsBeforeTheLater() {
        let scene = scene()
        let gap = offset(of: "Second") - 1
        let placed = PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [anchor("a", at: gap)], saved: ["a"])
        XCTAssertEqual(placed.holdStarts[-1], offset(of: "Second"))
    }

    func testAnAnchorAtTheStartStandsFirstAndOnePastTheLastSentenceStandsAfterIt() {
        let scene = scene()
        let last = text.count - 2
        let placed = PlaybackLivePassage.ClipPlacement.items(
            scene: scene, anchors: [anchor("a", at: 0), anchor("b", at: last)], saved: ["a", "b"])
        XCTAssertEqual(placed.items.first?.id, -1)
        XCTAssertEqual(placed.items.last?.id, -2)
        XCTAssertEqual(placed.holdStarts[-2], scene.sentences.last?.end, "a card after the last sentence is never held")
    }

    func testThreeCardsOnOneSentenceStandInTheOrderOfTheAnchorList() {
        let scene = scene()
        let at = offset(of: "Table 1")
        let placed = PlaybackLivePassage.ClipPlacement.items(
            scene: scene, anchors: [anchor("a", at: at), anchor("b", at: at), anchor("c", at: at)], saved: ["a", "b", "c"])
        XCTAssertEqual(placed.clipIds, [-1, -2, -3])
        XCTAssertEqual(placed.items.filter { $0.sentence == nil }.count, 3)
        XCTAssertEqual(placed.items.count, scene.sentences.count + 3)
    }

    func testAFloatWhoseFileIsMissingHasNoCard() {
        let scene = scene()
        let placed = PlaybackLivePassage.ClipPlacement.items(
            scene: scene, anchors: [anchor("here", at: 0), anchor("gone", at: offset(of: "Table 1"))], saved: ["here"])
        XCTAssertEqual(placed.clipIds, [-1], "the id is the place in the anchor list, so the survivor keeps -1")
        XCTAssertEqual(PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [anchor("gone", at: 0)], saved: []).items.count,
                       scene.sentences.count)
    }

    func testACardShowsOnlyInTheSceneWhoseRangeHoldsItsAnchor() {
        let first = "Alpha one. Alpha two. ", second = "Beta one. Beta two."
        let all = first + second
        let chapters = [Chapter(id: "1", title: "A", startChar: 0, endChar: first.count, percent: 0),
                        Chapter(id: "2", title: "B", startChar: first.count, endChar: all.count, percent: 50)]
        let inSecond = anchor("b", at: first.count + 2)
        let sceneA = scene(text: all, chapters: chapters, at: 0), sceneB = scene(text: all, chapters: chapters, at: first.count + 1)
        XCTAssertEqual(sceneA.chapterEnd, first.count)
        XCTAssertEqual(sceneB.chapterEnd, all.count)
        XCTAssertTrue(PlaybackLivePassage.ClipPlacement.items(scene: sceneA, anchors: [inSecond], saved: ["b"]).clipIds.isEmpty)
        XCTAssertEqual(PlaybackLivePassage.ClipPlacement.items(scene: sceneB, anchors: [inSecond], saved: ["b"]).clipIds, [-1])
    }

    func testASceneWithNoSentencesHasNoCards() {
        let placed = PlaybackLivePassage.ClipPlacement.items(scene: .empty, anchors: [anchor("a", at: 0)], saved: ["a"])
        XCTAssertTrue(placed.items.isEmpty)
    }

    func testCardIdsNeverMatchASentenceId() {
        let scene = scene()
        let placed = PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [anchor("a", at: 0)], saved: ["a"])
        XCTAssertEqual(Set(placed.items.map(\.id)).count, placed.items.count)
        XCTAssertTrue(placed.items.filter { $0.sentence != nil }.allSatisfy { $0.id >= 0 })
    }

    // MARK: Scene state

    func testSettingCardsPutsThemInTheShownSceneAndMovesTheRevision() {
        var state = PlaybackNowSceneState(text: text)
        state.move(offset: 0)
        XCTAssertEqual(state.shownItems.count, state.shownScene.sentences.count, "no cards until they are set")
        let revision = state.sceneRevision
        state.setClips(anchors: [anchor("a", at: offset(of: "Table 1"))], saved: ["a"])
        XCTAssertEqual(state.shownItems.count, state.shownScene.sentences.count + 1)
        XCTAssertGreaterThan(state.sceneRevision, revision, "a view that compares revisions sees the new cards")
        XCTAssertEqual(state.clipHoldStarts[-1], offset(of: "Table 1"))
        // The same cards again change nothing.
        let after = state.sceneRevision
        state.setClips(anchors: [anchor("a", at: offset(of: "Table 1"))], saved: ["a"])
        XCTAssertEqual(state.sceneRevision, after)
    }

    func testATickInTheSameSceneRebuildsNoItems() {
        var state = PlaybackNowSceneState(text: text)
        state.move(offset: 0)
        state.setClips(anchors: [anchor("a", at: offset(of: "Table 1"))], saved: ["a"])
        let items = state.shownItems, revision = state.sceneRevision
        state.move(offset: offset(of: "Caption"))
        XCTAssertEqual(state.sceneRevision, revision)
        XCTAssertEqual(state.shownItems, items)
        XCTAssertNotNil(state.litSentence)
    }

    func testAChapterChangeGivesTheNewScenesItemsInTheSameUpdate() {
        let first = "Alpha one. Alpha two. ", second = "Beta one. Beta two."
        let all = first + second
        let chapters = [Chapter(id: "1", title: "A", startChar: 0, endChar: first.count, percent: 0),
                        Chapter(id: "2", title: "B", startChar: first.count, endChar: all.count, percent: 50)]
        var state = PlaybackNowSceneState(text: all, chapters: chapters)
        state.move(offset: 0)
        state.setClips(anchors: [anchor("b", at: first.count + 2)], saved: ["b"])
        XCTAssertEqual(state.shownItems.filter { $0.sentence == nil }.count, 0, "the card is in the other scene")
        state.move(offset: first.count + 1)
        XCTAssertEqual(state.shownScene.chapterTitle, "B")
        XCTAssertEqual(state.shownItems.filter { $0.sentence == nil }.count, 1)
        XCTAssertEqual(state.shownItems.count, state.shownScene.sentences.count + 1)
    }

    func testNoCardsLeavesTheItemsExactlyTheSceneSentences() {
        var state = PlaybackNowSceneState(text: text)
        state.move(offset: 0)
        XCTAssertEqual(state.shownItems, state.shownScene.sentences.map { .sentence($0) })
        state.setClips(anchors: [anchor("a", at: 0)], saved: [])
        XCTAssertEqual(state.shownItems, state.shownScene.sentences.map { .sentence($0) })
    }

    // MARK: The hold

    private func holdScene(count: Int) -> PlaybackLivePassage.Scene {
        scene(text: (1...count).map { "Sentence number \($0) here." }.joined(separator: " "))
    }

    private func target(_ scene: PlaybackLivePassage.Scene, lit: Int, clips: [(id: Int, holdIndex: Int, height: Double)],
                        visible: Double = 450, row: @escaping (Int) -> Double = { _ in 60 }) -> PlaybackLivePassage.ScrollTarget {
        PlaybackLivePassage.ClipHold.target(
            scene: scene, lit: lit,
            clips: clips.map { ($0.id, scene.sentences[$0.holdIndex].start, $0.height) },
            visibleHeight: visible, sentenceHeight: row)
    }

    func testBeforeTheCardsSentenceFollowingUsesItsUsualLine() {
        let scene = holdScene(count: 12)
        XCTAssertEqual(target(scene, lit: 3, clips: [(-1, 5, 150)]), .sentence)
    }

    func testAtTheCardsSentenceTheCardIsHeldAtTheTop() {
        let scene = holdScene(count: 12)
        XCTAssertEqual(target(scene, lit: 5, clips: [(-1, 5, 150)]), .clip(id: -1))
        XCTAssertEqual(target(scene, lit: 6, clips: [(-1, 5, 150)]), .clip(id: -1))
    }

    func testTheHoldEndsWhenWhatWasReadNoLongerFitsUnderTheCard() {
        let scene = holdScene(count: 12)
        // 150 + 12 + 60 per sentence: four sentences (5 to 8) take 402 of 450, a fifth takes 462.
        XCTAssertEqual(target(scene, lit: 8, clips: [(-1, 5, 150)]), .clip(id: -1))
        XCTAssertEqual(target(scene, lit: 9, clips: [(-1, 5, 150)]), .sentence)
    }

    func testATallSentenceBetweenTheCardAndTheLitSentenceEndsTheHold() {
        let scene = holdScene(count: 12)
        let tall: (Int) -> Double = { $0 == 5 ? 25 * 20 + 20 : 60 }
        XCTAssertEqual(target(scene, lit: 6, clips: [(-1, 5, 150)], row: tall), .sentence)
        XCTAssertEqual(target(scene, lit: 5, clips: [(-1, 5, 150)], row: tall), .sentence, "a lit sentence that starts inside but ends past what fits")
    }

    func testManyShortCaptionSentencesHoldOnlyWhileTheyFit() {
        let scene = holdScene(count: 20)
        let short: (Int) -> Double = { _ in 44 + PlaybackLivePassage.ClipHold.rowSpacing }
        XCTAssertEqual(target(scene, lit: 9, clips: [(-1, 5, 150)], row: short), .clip(id: -1))
        XCTAssertEqual(target(scene, lit: 12, clips: [(-1, 5, 150)], row: short), .sentence)
    }

    func testTheLaterOfTwoOverlappingHoldsWins() {
        let scene = holdScene(count: 12)
        let clips: [(id: Int, holdIndex: Int, height: Double)] = [(-1, 4, 100), (-2, 5, 100)]
        XCTAssertEqual(target(scene, lit: 5, clips: clips), .clip(id: -2))
        XCTAssertEqual(target(scene, lit: 4, clips: clips), .clip(id: -1))
    }

    func testACardAmongTheRowsReadSinceTakesItsHeightToo() {
        let scene = holdScene(count: 12)
        // Lit 6 holds card -1: 100 + 12 + two rows of 60 is 232. Lit 7 is at the later card, which wins.
        let clips: [(id: Int, holdIndex: Int, height: Double)] = [(-1, 5, 100), (-2, 7, 150)]
        // Lit at 7, the later card is also at or before the lit sentence and wins.
        XCTAssertEqual(target(scene, lit: 7, clips: clips), .clip(id: -2))
        XCTAssertEqual(target(scene, lit: 6, clips: clips), .clip(id: -1))
        XCTAssertEqual(target(scene, lit: 6, clips: clips, visible: 200), .sentence)
    }

    func testATooTallLaterCardAmongTheRowsReadSinceEndsTheEarlierHold() {
        let scene = holdScene(count: 12)
        let clips: [(id: Int, holdIndex: Int, height: Double)] = [(-1, 5, 100), (-2, 7, 400)]
        // Lit at 7: card -2 alone does not fit, and card -1 would need its rows and card -2 too.
        XCTAssertEqual(target(scene, lit: 7, clips: clips), .sentence)
    }

    func testCardsBeforeTheSameSentenceAreAllPartOfTheHeldExtent() {
        let scene = holdScene(count: 12)
        // A table split over two pages: two cards, one caption. The second card sits between the first and the caption.
        XCTAssertEqual(target(scene, lit: 5, clips: [(-1, 5, 100), (-2, 5, 400)]), .sentence)
        XCTAssertEqual(target(scene, lit: 5, clips: [(-1, 5, 100), (-2, 5, 100)]), .clip(id: -2))
    }

    func testACardInTheGapBetweenChaptersIsInNoScene() {
        let all = "Alpha one. Alpha two. GAP GAP. Beta one. Beta two."
        let gapStart = (all as NSString).range(of: "GAP").location, betaStart = (all as NSString).range(of: "Beta one").location
        let chapters = [Chapter(id: "1", title: "A", startChar: 0, endChar: gapStart, percent: 0),
                        Chapter(id: "2", title: "B", startChar: betaStart, endChar: all.count, percent: 50)]
        let inGap = anchor("g", at: gapStart + 2)
        for at in [0, betaStart + 1] {
            let scene = scene(text: all, chapters: chapters, at: at)
            XCTAssertTrue(PlaybackLivePassage.ClipPlacement.items(scene: scene, anchors: [inGap], saved: ["g"]).clipIds.isEmpty)
        }
    }

    func testACardAfterTheLastSentenceOrAnInvalidLitSentenceNeverHolds() {
        let scene = holdScene(count: 4)
        let last = scene.sentences[3]
        let after = PlaybackLivePassage.ClipHold.target(
            scene: scene, lit: 3, clips: [(-1, last.end, 100)], visibleHeight: 450, sentenceHeight: { _ in 60 })
        XCTAssertEqual(after, .sentence)
        XCTAssertEqual(target(scene, lit: 99, clips: [(-1, 1, 100)]), .sentence)
        XCTAssertEqual(target(scene, lit: 2, clips: [(-1, 1, 100)], visible: 0), .sentence)
    }

    // MARK: Heights

    private func fragment(_ text: String, role: StructuredDocument.Role = .body, label: String? = nil) -> PlaybackLivePassage.Fragment {
        PlaybackLivePassage.Fragment(id: UUID().uuidString, start: 0, text: text, role: role, label: label, pageIndex: nil)
    }

    func testARowsHeightCountsEachLineBreakAndTheLabelAndTheTableFont() {
        let metrics = PlaybackLivePassage.ClipHold.Metrics(columnWidth: 300, visibleHeight: 450, bodyPointSize: 17, lineHeight: 22)
        let height = { PlaybackLivePassage.ClipHold.rowHeight(fragments: $0, metrics: metrics) }
        // 300 / 8.5 is 35 characters a line in body type; 300 / 10.2 is 29 in monospace. Padding 20, floor 44, spacing 10.
        XCTAssertEqual(height([fragment("short")]), 44 + 10, "one line is under the floor")
        XCTAssertEqual(height([fragment(String(repeating: "x", count: 36))]), 2 * 22 + 20 + 10)
        XCTAssertEqual(height([fragment("one\ntwo\nthree")]), 3 * 22 + 20 + 10, "each line break starts a line")
        XCTAssertEqual(height([fragment(String(repeating: "x", count: 30), role: .table)]), 2 * 22 + 20 + 10)
        XCTAssertEqual(height([fragment(String(repeating: "x", count: 30), role: .body)]), 44 + 10)
        XCTAssertEqual(height([fragment("a\nb", label: "Table 2"), fragment("c")]), 4 * 22 + 20 + 4 + 10,
                       "a label is one more line, and a second fragment adds the 4 point gap between fragments")
    }

    func testAtTheLargestTextSizeNoHoldFits() {
        let big = PlaybackLivePassage.ClipHold.Metrics(columnWidth: 300, visibleHeight: 450, bodyPointSize: 53, lineHeight: 64)
        let sentence = fragment("Figure 3. Accuracy by model across the three arms of the study.")
        let row = PlaybackLivePassage.ClipHold.rowHeight(fragments: [sentence], metrics: big)
        XCTAssertGreaterThan(row, 400)
        let scene = holdScene(count: 6)
        XCTAssertEqual(target(scene, lit: 2, clips: [(-1, 2, 150)], visible: big.visibleHeight, row: { _ in row }), .sentence)
        XCTAssertEqual(PlaybackLivePassage.ClipHold.rowHeight(fragments: [sentence], metrics: .init(columnWidth: 0, visibleHeight: 1, bodyPointSize: 17, lineHeight: 22)), .infinity)
    }

    // MARK: Card size

    func testACardIsTheListWidthLessTheGutterAndItsHeightFollowsTheAspect() {
        typealias Layout = PlaybackLivePassage.ClipCardLayout
        XCTAssertEqual(Layout.width(listWidth: 350), 322)
        XCTAssertEqual(Layout.width(listWidth: 10), 0, "never negative")
        // Aspect is width over height: 322 wide at 2.0 is 161 tall.
        XCTAssertEqual(Layout.height(width: 322, aspect: 2, visibleHeight: 800), 161)
        // A tall picture is held at 220 points, or at 45% of a short text area when that is less.
        XCTAssertEqual(Layout.height(width: 322, aspect: 0.5, visibleHeight: 800), 220)
        XCTAssertEqual(Layout.height(width: 322, aspect: 0.5, visibleHeight: 400), 180, accuracy: 0.001)
        // A wide strip is held at the 44 point minimum, so it is still a target a finger can hit.
        XCTAssertEqual(Layout.height(width: 322, aspect: 20, visibleHeight: 800), 44)
        // A text area so short that 45% is under the minimum still gives the minimum, never less.
        XCTAssertEqual(Layout.height(width: 322, aspect: 1, visibleHeight: 50), 44)
        XCTAssertEqual(Layout.tallest(visibleHeight: 0), 44)
    }

    func testACardWithNoUsableAspectOrWidthGetsTheMinimum() {
        typealias Layout = PlaybackLivePassage.ClipCardLayout
        for aspect in [0.0, -1.0, .nan, .infinity] {
            XCTAssertEqual(Layout.height(width: 322, aspect: aspect, visibleHeight: 800), 44, "aspect \(aspect)")
        }
        XCTAssertEqual(Layout.height(width: 0, aspect: 1.5, visibleHeight: 800), 44)
        XCTAssertEqual(Layout.height(width: -5, aspect: 1.5, visibleHeight: 800), 44)
    }

    // MARK: A hold that failed is not tried again

    func testACardWhoseHoldWasDroppedDoesNotHoldAtTheNextSentenceEither() {
        let scene = holdScene(count: 12)
        let clips = [(id: -1, holdStart: scene.sentences[3].start, height: 150.0)]
        let hold = { (lit: Int, dropped: Set<Int>) in
            PlaybackLivePassage.ClipHold.target(
                scene: scene, lit: lit, clips: clips, visibleHeight: 450, dropped: dropped, sentenceHeight: { _ in 60 })
        }
        XCTAssertEqual(hold(4, []), .clip(id: -1), "the estimate says it fits")
        // The view found sentence 4 off screen and dropped the card: sentences 4, 5 and 6 follow the usual way, so the text
        // does not move up and down once per sentence.
        for lit in 4...6 { XCTAssertEqual(hold(lit, [-1]), .sentence, "sentence \(lit)") }
    }

    func testADroppedCardHoldsAgainOnlyOnceTheListenerIsBeforeIt() {
        let scene = holdScene(count: 12)
        let starts = [-1: scene.sentences[3].start, -2: scene.sentences[8].start]
        typealias Hold = PlaybackLivePassage.ClipHold
        XCTAssertEqual(Hold.stillDropped([-1, -2], holdStarts: starts, litStart: scene.sentences[5].start), [-1],
                       "the card not reached yet was never dropped for this reading; the reached one stays dropped")
        XCTAssertEqual(Hold.stillDropped([-1], holdStarts: starts, litStart: scene.sentences[3].start), [-1], "at its own sentence")
        XCTAssertEqual(Hold.stillDropped([-1], holdStarts: starts, litStart: scene.sentences[1].start), [],
                       "a rewind to before the card gives it its hold again")
        XCTAssertEqual(Hold.stillDropped([-9], holdStarts: starts, litStart: 0), [], "a card that is gone")
    }
}
