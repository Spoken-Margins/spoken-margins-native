import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    func testOpeningAnItemRetainsRichSourceRolesInTimelineAndNow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let store = try SQLiteSessionStore(path: database.path)
        let text = "Caption\n\nCell A | Cell B\n\nA footnote"
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: text,
            segments: [
                .init(id: "caption", role: .caption, range: .init(start: 0, length: 7), pageIndex: 0),
                .init(id: "table", role: .table, range: .init(start: 9, length: 15), pageIndex: 0),
                .init(id: "footnote", role: .footnote, range: .init(start: 26, length: 10), pageIndex: 1)
            ], markers: [],
            floats: [.init(id: "figure", kind: .figure, label: "Figure 1: authored label", pageIndex: 0,
                           bounds: .init(x: 0, y: 0, width: 1, height: 1), captionSegmentId: "caption")])
        for nativeAudio in [false, true] {
            let item = Item(id: nativeAudio ? "podcast" : "pdf", title: "Authored source",
                            mediaType: nativeAudio ? TargetType.transcriptBackedMedia.rawValue : "pdf",
                            text: text, externalReference: "https://example.invalid/source", status: "Ready",
                            media: nativeAudio ? ItemMedia(sourceType: .remoteStream,
                                url: "https://example.invalid/audio.mp3", durationMs: 60_000) : nil)
            try store.saveItem(item)
            try store.saveStructuredDocument(document, itemId: item.id)
        }
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.bootstrapLibraryIfNeeded()
        model.openItem(id: "pdf")
        let entries = ExperienceTimelineRailScreen.makeEntries(from: model.selectedItem, sessionID: nil)
        let source = model.selectedItem.timelineSource.entries
        XCTAssertEqual(source.map(\.text), ["Caption", "Cell A | Cell B", "A footnote"])
        XCTAssertEqual(source.map(\.role), [.caption, .table, .footnote])
        XCTAssertEqual(source.map(\.pageIndex), [0, 0, 1])
        XCTAssertEqual(source.first?.label, "Figure 1: authored label")
        let richSource = entries.compactMap { entry -> TimelineSourceContent.Entry? in
            guard case .sourceText(let source) = entry.action else { return nil }
            return source
        }
        XCTAssertEqual(richSource, source, "Retained captions, tables and footnotes stay in Timeline")
        let index = PlaybackLivePassage.SourceIndex(model.selectedItem.timelineSource)
        let sentence = PlaybackLivePassage.Sentence(start: 0, end: 7, text: "Caption", isCurrent: true, diamonds: [])
        XCTAssertEqual(index.fragments(for: sentence).first?.label, "Figure 1: authored label",
                       "Now still annotates the retained source passage")

        model.openItem(id: "podcast")
        XCTAssertTrue(model.selectedItem.isNativeAudio)
        XCTAssertTrue(model.selectedItem.timelineSource.entries.isEmpty,
                      "An audio transcript must not become source text without time mapping")
    }

    func testTimelineKeepsOnlySupportedRichSourceElementsAlongsideNavigation() {
        let roles = StructuredDocument.Role.allCases
        let text = roles.map { $0.rawValue + "." }.joined(separator: "\n\n")
        var start = 0
        let segments = roles.enumerated().map { index, role -> StructuredDocument.Segment in
            let length = role.rawValue.count + 1
            defer { start += length + 2 }
            return .init(id: "segment-\(index)", role: role, range: .init(start: start, length: length))
        }
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text, segments: segments, markers: [])
        let item = ItemDetailState(id: "rich-source", title: "Document", text: text).includingTimelineSource(document)
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let displayed = entries.compactMap { entry -> StructuredDocument.Role? in
            guard case .sourceText(let source) = entry.action else { return nil }
            return source.role
        }
        XCTAssertEqual(displayed, [.caption, .table, .footnote, .reference, .figureText],
                       "Pictures/embeds/link payloads are not retained by this schema; metadata and headings are not scenes")
        XCTAssertEqual(item.timelineSource.entries.map(\.role), roles, "Now and the reader still receive every retained role")
    }

    /// 2026-11-14: a table is a Timeline row named by its columns; a link row's tap goes straight to its address; a
    /// picture and a YouTube embed have a picture to draw, a link and a table don't.
    func testTableRowsLinkTapsAndPreviewPictures() throws {
        let text = "Intro paragraph.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nSee the study here."
        let tableStart = try XCTUnwrap(text.range(of: "| A")).lowerBound.utf16Offset(in: text)
        let record = SourceElementsRecord(text: text, elements: [
            SourceElement(id: "t0", kind: .table, start: tableStart, label: "A · B", url: "", rows: [["A", "B"], ["1", "2"]]),
            SourceElement(id: "l0", kind: .link, start: text.count - 10, label: "the study", url: "https://example.com/study")
        ])
        let item = ItemDetailState(id: "web", title: "Post", text: text).includingTimelineSource(nil, elements: record)
        let rows = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil).filter {
            if case .sourceElement = $0.action { return true } else { return false }
        }
        XCTAssertEqual(rows.map(\.title), ["A · B", "the study"])
        XCTAssertEqual(rows.map(\.detail), ["Table", "Link · example.com"])
        XCTAssertEqual(rows.map(\.provenanceLabel), ["Table", "Link"])

        let link = record.elements[1]
        XCTAssertEqual(link.linkDestination?.absoluteString, "https://example.com/study")
        XCTAssertNil(record.elements[0].linkDestination)
        XCTAssertNil(SourceElement(id: "x", kind: .link, start: 0, label: "x", url: "javascript:alert(1)").linkDestination)
        XCTAssertNil(SourceElement(id: "p", kind: .picture, start: 0, label: "p", url: "https://x.example/p.gif").linkDestination,
                     "a picture opens its sheet, not the address")

        XCTAssertEqual(SourceElement(id: "p", kind: .picture, start: 0, label: "p", url: "https://x.example/p.gif").previewImageURL?.absoluteString,
                       "https://x.example/p.gif")
        XCTAssertNil(link.previewImageURL)
        XCTAssertNil(record.elements[0].previewImageURL)
    }

    /// Neighbouring inputs for the YouTube still: each address form, lookalike hosts, and ids that aren't ids.
    func testYouTubeStillAddresses() {
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=abc123XYZ_-", "abc123XYZ_-"),
            ("https://m.youtube.com/watch?v=abc123XYZ&t=10", "abc123XYZ"),
            ("https://youtu.be/abc123XYZ?si=share", "abc123XYZ"),
            ("https://www.youtube.com/embed/abc123XYZ", "abc123XYZ"),
            ("https://www.youtube-nocookie.com/embed/abc123XYZ", "abc123XYZ"),
            ("https://youtube.com/shorts/abc123XYZ", "abc123XYZ"),
            ("https://www.youtube.com/channel/UCxyz", nil),
            ("https://www.youtube.com/watch", nil),
            ("https://notyoutube.com/watch?v=abc123XYZ", nil),
            ("https://youtube.com.evil.example/watch?v=abc123XYZ", nil),
            ("https://www.youtube.com/watch?v=../../x", nil),
            ("https://vimeo.com/12345678", nil)
        ]
        for (address, id) in cases {
            XCTAssertEqual(SourceElement.youTubeID(address), id, address)
        }
        XCTAssertEqual(SourceElement(id: "e", kind: .embed, start: 0, label: "YouTube video", url: "https://youtu.be/abc123XYZ").previewImageURL?.absoluteString,
                       "https://i.ytimg.com/vi/abc123XYZ/hqdefault.jpg")
    }

    /// #3895: a PDF's chapters fold. Folding the dense one hides its table and figure text, keeps every chapter row,
    /// and a Margin the listener is taken to unfolds the chapter that held it.
    func testFoldingAChapterHidesItsRowsAndKeepsTheNextChapterReachable() {
        let text = "Intro.\n\nTable A | B\n\nText in figure\n\nSecond chapter body."
        let tableStart = (text as NSString).range(of: "Table").location
        let figureStart = (text as NSString).range(of: "Text in").location
        let secondStart = (text as NSString).range(of: "Second").location
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: text,
            segments: [
                .init(id: "table", role: .table, range: .init(start: tableStart, length: 9), pageIndex: 0),
                .init(id: "figure", role: .figureText, range: .init(start: figureStart, length: 14), pageIndex: 0)
            ], markers: [])
        var item = ItemDetailState(id: "pdf", title: "Paper", text: text).includingTimelineSource(document)
        item.chapters = [
            Chapter(id: "c1", title: "1 Introduction", startChar: 0, endChar: secondStart, percent: 0),
            Chapter(id: "c2", title: "2 Method", startChar: secondStart, endChar: text.count, percent: 70)
        ]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let rows = entries.map(\.foldingRow)
        XCTAssertEqual(entries.count, 4, "two chapters, the table and the figure text")
        XCTAssertEqual([entries.first?.id, entries.last?.id], ["source.chapter.c1", "source.chapter.c2"])
        XCTAssertEqual(rows.filter(\.isChapter).map(\.id), ["source.chapter.c1", "source.chapter.c2"],
                       "only chapters open a section, not the rich source rows")

        var folding = TimelineChapterFolding()
        folding.toggle("source.chapter.c1", in: rows)
        let visible = folding.visibleRows(in: rows).map(\.id)
        XCTAssertTrue(visible.contains("source.chapter.c1") && visible.contains("source.chapter.c2"))
        XCTAssertEqual(visible.count, 2, "the table and the figure text are folded under the first chapter")
        XCTAssertEqual(folding.summary(forChapter: "source.chapter.c1", in: rows, currentIDs: [])?.hiddenCount, 2)

        let tableRowID = entries.first { if case .sourceText(let e) = $0.action { return e.role == .table } else { return false } }?.id
        XCTAssertNotNil(tableRowID)
        XCTAssertTrue(folding.reveal(tableRowID ?? "", in: rows))
        XCTAssertEqual(folding.visibleRows(in: rows).count, rows.count)
    }

    /// #4586: a PDF's Timeline opens with only the playing chapter expanded, built from the real rail rows, and
    /// playback moving into the next chapter folds the first and opens the second.
    func testTimelineOpensWithOnlyThePlayingChapterExpandedAndFollowsPlayback() {
        let text = "Intro.\n\nTable A | B\n\nText in figure\n\nSecond chapter body.\n\nSecond table | C"
        let tableStart = (text as NSString).range(of: "Table A").location
        let figureStart = (text as NSString).range(of: "Text in").location
        let secondStart = (text as NSString).range(of: "Second chapter").location
        let table2Start = (text as NSString).range(of: "Second table").location
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: text,
            segments: [
                .init(id: "table", role: .table, range: .init(start: tableStart, length: 9), pageIndex: 0),
                .init(id: "figure", role: .figureText, range: .init(start: figureStart, length: 14), pageIndex: 0),
                .init(id: "table2", role: .table, range: .init(start: table2Start, length: 14), pageIndex: 1)
            ], markers: [])
        var item = ItemDetailState(id: "pdf2", title: "Paper", text: text).includingTimelineSource(document)
        item.chapters = [
            Chapter(id: "c1", title: "1 Introduction", startChar: 0, endChar: secondStart, percent: 0),
            Chapter(id: "c2", title: "2 Method", startChar: secondStart, endChar: text.count, percent: 70)
        ]
        let rows = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil).map(\.foldingRow)
        let c1 = "source.chapter.c1", c2 = "source.chapter.c2"
        XCTAssertEqual(rows.filter(\.isChapter).map(\.id), [c1, c2])

        var folding = TimelineChapterFolding()
        folding.sync(rows: rows, currentIDs: [c1])
        XCTAssertEqual(folding.foldedChapterIDs, [c2], "the playing chapter is open, the other is folded")
        XCTAssertEqual(folding.visibleRows(in: rows).count, rows.count - TimelineChapterFolding.members(in: rows)[c2]!.count)

        folding.sync(rows: rows, currentIDs: [c2])
        XCTAssertEqual(folding.foldedChapterIDs, [c1], "playback entered the second chapter")
    }

    /// #2032: pictures, embeds and links an imported Substack page kept are Timeline rows, in text order and
    /// labelled; a page that kept none shows none, and ordinary paragraphs still get no row of their own.
    func testTimelineShowsKeptPicturesEmbedsAndLinksAndNoEmptyRows() throws {
        let text = "Intro paragraph.\n\nA chart caption.\n\nSee the study here.\n\nClosing paragraph."
        let characters = text.count
        let chartStart = try XCTUnwrap(text.range(of: "A chart")).lowerBound.utf16Offset(in: text)
        let linkStart = try XCTUnwrap(text.range(of: "the study")).lowerBound.utf16Offset(in: text)
        let record = SourceElementsRecord(text: text, elements: [
            SourceElement(id: "e0", kind: .picture, start: chartStart, label: "A chart caption.",
                          altText: "Rates", url: "https://substackcdn.com/a.jpg"),
            SourceElement(id: "e1", kind: .link, start: linkStart, label: "the study", url: "https://www.example.com/study"),
            SourceElement(id: "e2", kind: .embed, start: characters, label: "YouTube video", url: "https://www.youtube.com/watch?v=x")
        ])
        let item = ItemDetailState(id: "substack", title: "Post", text: text).includingTimelineSource(nil, elements: record)
        let rows = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let elementRows = rows.filter { if case .sourceElement = $0.action { return true } else { return false } }
        XCTAssertEqual(elementRows.map(\.title), ["A chart caption.", "the study", "YouTube video"])
        XCTAssertEqual(elementRows.map(\.detail), ["Picture", "Link · example.com", "Embed"])
        XCTAssertEqual(elementRows.map(\.position), elementRows.map(\.position).sorted())
        XCTAssertEqual(elementRows.map(\.accessibilityIdentifier),
                       ["timeline.sourceElement.e0", "timeline.sourceElement.e1", "timeline.sourceElement.e2"])
        XCTAssertEqual(rows.count, elementRows.count + 1, "only the beginning and the kept elements: no row per paragraph")

        let none = ItemDetailState(id: "plain", title: "Post", text: text).includingTimelineSource(nil)
        XCTAssertEqual(ExperienceTimelineRailScreen.makeEntries(from: none, sessionID: nil).map(\.id), ["source.beginning"])
        // Elements made for other text are ignored.
        let stale = ItemDetailState(id: "edited", title: "Post", text: text + " edited").includingTimelineSource(nil, elements: record)
        XCTAssertEqual(ExperienceTimelineRailScreen.makeEntries(from: stale, sessionID: nil).map(\.id), ["source.beginning"])
    }

    func testParagraphsDoNotInventNavigationWhenAnArticleHasNoScenes() {
        for text in ["", "One paragraph.", "First.\n\nSecond.\n \nThird.",
                     (0..<100).map { "Paragraph \($0)." }.joined(separator: "\n\n")] {
            let item = ItemDetailState(id: "article", title: "Article", text: text).includingTimelineSource(nil)
            let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
            XCTAssertTrue(item.chapters.isEmpty)
            XCTAssertTrue(item.listeningMapScenes.isEmpty)
            XCTAssertEqual(entries.map(\.id), ["source.beginning"], "No invented navigation for \(text.count) characters")
        }
    }

    func testRealNavigationAppearsOnceWithoutParagraphRows() {
        var item = ItemDetailState(id: "article", title: "Article", text: "First.\n\nSecond.")
            .includingTimelineSource(nil)
        item.chapters = [.init(id: "authored", title: "Opening", startChar: 0, endChar: 15, percent: 0)]
        item.mediaChapters = [
            .init(id: "authored", title: "Opening", startMs: 0, transcriptSegmentId: "first"),
            .init(id: "publisher", title: "Publisher chapter", startMs: 30_000, transcriptSegmentId: "second")
        ]
        item.listeningMapScenes = [.init(id: "scene", title: "A real scene", startMs: 45_000, transcriptSegmentId: "third")]
        item.mediaDurationMs = 60_000
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        XCTAssertEqual(entries.map(\.id), ["source.chapter.authored", "source.mediaChapter.publisher", "source.listeningMapScene.scene"])
        XCTAssertEqual(entries.map(\.title), ["Opening", "Publisher chapter", "A real scene"])
        guard case .chapter = entries[0].action, case .mediaChapter = entries[1].action,
              case .listeningMapScene = entries[2].action else { return XCTFail("Navigation actions were lost") }
    }

    func testPlaybackFocusNeverTargetsAnOmittedParagraphOrAnEarlierCaption() throws {
        let text = "Caption\n\nBody paragraph."
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: text, segments: [
                .init(id: "caption", role: .caption, range: .init(start: 0, length: 7)),
                .init(id: "body", role: .body, range: .init(start: 9, length: 15))
            ], markers: [])
        var item = ItemDetailState(id: "article", title: "Article", text: text).includingTimelineSource(document)
        item.chapters = [.init(id: "scene", title: "Actual scene", startChar: 0, endChar: text.count, percent: 0)]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        var snapshot = SessionSnapshot()
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.status = .playing
        let source = try XCTUnwrap(item.timelineSource.entries.first { $0.role == .caption })
        for offset in [2, 7, 8, 10, text.count] {
            snapshot.currentTextStart = offset
            let selection = ExperienceTimelineRailScreen.selectionForPlayback(entries: entries, item: item, snapshot: snapshot) {
                if case .chapter = $0 { true } else { false }
            }
            XCTAssertEqual(selection.focusID, offset < 7 ? source.id : "source.chapter.scene")
            XCTAssertEqual(selection.currentIDs, offset < 7 ? [source.id, "source.chapter.scene"] : ["source.chapter.scene"])
            XCTAssertTrue(entries.contains { $0.id == selection.focusID }, "Follow playback must scroll to a displayed row")
        }
        for text in ["", "Only body text."] {
            let item = ItemDetailState(id: "article", text: text).includingTimelineSource(nil)
            let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
            snapshot.currentTextStart = 0
            let selection = ExperienceTimelineRailScreen.selectionForPlayback(entries: entries, item: item, snapshot: snapshot) { _ in false }
            XCTAssertEqual(selection.focusID, "source.beginning")
            XCTAssertTrue(selection.currentIDs.isEmpty)
        }
    }

    /// #1291 APO-09: `Gate1FlowUITests` checked only that some Timeline row reads "Current chapter." after Next
    /// chapter, which is true before the jump too, and that class runs nowhere. Here the model's real Next chapter
    /// press must move the Timeline's current chapter from the one playing to the next one, and only that one.
    func testNextChapterMovesTheTimelinesCurrentChapterToTheNextChapter() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let (model, cleanUp) = try seededModel()
        defer { cleanUp() }
        model.startItem(id: "item-pill")
        let before = currentTimelineChapterIDs(model)
        XCTAssertEqual(before.count, 1, "precondition: one Timeline chapter is current while the item plays")
        let next = try XCTUnwrap(model.nextPlaybackChapter, "precondition: the seeded item has a next chapter")
        XCTAssertNotEqual(before, [next.id])
        XCTAssertTrue(model.canJumpToNextChapter)

        model.jumpToNextChapter()

        XCTAssertEqual(currentTimelineChapterIDs(model), [next.id], "Next chapter moves the Timeline's current chapter")
        XCTAssertEqual(model.snapshot.chapterTitle, next.title)
        XCTAssertEqual(model.screen, .playback)
    }

    /// #1291 APO-09: the same UI test tapped the forward and back buttons and asserted nothing. A text item's
    /// skip forward must move the reading position on, and skip back must move it back again.
    func testTextSkipForwardThenBackMovesTheReadingPositionOnAndBack() throws {
        let restoreTerms = acceptTerms()
        defer { restoreTerms() }
        let (model, cleanUp) = try seededModel()
        defer { cleanUp() }
        model.startItem(id: "item-pill")
        model.skipUnit = "paragraph"
        let start = try XCTUnwrap(model.snapshot.currentTextStart, "precondition: the item is read as text")

        model.skipForward()
        let forward = try XCTUnwrap(model.snapshot.currentTextStart)
        XCTAssertGreaterThan(forward, start, "skip forward moves the reading position on")

        model.skipBack()
        let back = try XCTUnwrap(model.snapshot.currentTextStart)
        XCTAssertLessThan(back, forward, "skip back moves the reading position back")
        XCTAssertNil(model.lastError)
    }

    private func seededModel() throws -> (Gate1AppModel, () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appendingPathComponent("library.sqlite"))
        model.resetAndSeed()
        return (model, { try? FileManager.default.removeItem(at: root) })
    }

    /// The chapter rows the Timeline marks "Current chapter", read the way the rail reads them.
    private func currentTimelineChapterIDs(_ model: Gate1AppModel) -> [String] {
        ExperienceTimelineRailScreen.makeEntries(from: model.selectedItem, sessionID: model.snapshot.sessionId)
            .compactMap { entry in
                guard case .chapter(let chapter) = entry.action, model.isCurrentTimelineChapter(chapter) else { return nil }
                return chapter.id
            }
    }

    /// The Terms gate holds text playback on a fresh simulator, so accept them for the test and put them back.
    private func acceptTerms() -> () -> Void {
        let keys = [SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        SpokenMarginsTerms.recordAcceptance()
        return {
            for (key, value) in zip(keys, prior) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    func testSourceChapterAndMarginUseUnroundedPositionsWithoutChangingActions() throws {
        var item = ItemDetailState(id: "item", title: "Article", text: String(repeating: "x", count: 1_000))
        let document = StructuredDocument(
            extraction: .init(engine: "test", version: 1, sourceSHA256: nil, pageCount: 1, textSHA256: nil),
            text: item.text,
            segments: [.init(id: "passage", role: .body, range: .init(start: 13, length: 1))], markers: [])
        item = item.includingTimelineSource(document)
        item.chapters = [.init(id: "chapter", title: "Chapter", startChar: 12, endChar: 999, percent: 1)]
        item.interjections = [.init(id: "margin", itemId: item.id, sessionId: "session", targetType: .item,
            targetId: item.id, createdAt: Date(), roughPercent: 1,
            anchor: .init(anchorType: .text, startChar: 11, endChar: 12, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "transcribed", transcript: "My thought",
            cleanedTranscript: nil, displayText: nil, status: "active")]
        item.turns = [.init(id: "reply", sessionId: "session", role: "assistant", turnType: "assistant_response",
                            status: "complete", text: "Response", sourceInterjectionIds: ["margin"])]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
        let relevant = entries.filter { entry in
            switch entry.action {
            case .margin, .chapter, .turn: true
            default: false
            }
        }
        XCTAssertEqual(relevant.map(\.position), [1, 1, 1])
        XCTAssertEqual(relevant.count, 3)
        XCTAssertFalse(entries.contains { if case .sourceText = $0.action { true } else { false } })
        for (entry, expected) in zip(relevant, [1.1, 1.1, 1.2]) {
            XCTAssertEqual(try XCTUnwrap(entry.precisePosition), expected, accuracy: 1e-9,
                           "Compare source coordinates before rounding for display")
        }
        XCTAssertEqual(relevant.map(\.accessibilityIdentifier).prefix(3),
                       ["timeline.interjection.margin", "timeline.turn.play.reply", "timeline.chapter.jump.chapter"],
                       "A response must follow its own Margin even inside one rounded percentage")
        guard case .margin = relevant.first?.action else { return XCTFail("Margin detail action was lost") }
        guard case .chapter = relevant.dropFirst(2).first?.action else { return XCTFail("Chapter seek action was lost") }
    }

    func testUnknownAudioDurationKeepsTheMarginAndResponseAtTheirRoughPosition() throws {
        for duration in [nil, 0, -1] as [Int?] {
            var item = ItemDetailState(id: "podcast", title: "Episode", mediaDurationMs: duration, isNativeAudio: true)
            item.interjections = [.init(id: "margin", itemId: item.id, sessionId: "session", targetType: .item,
                targetId: item.id, createdAt: Date(), roughPercent: 20,
                anchor: .init(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "",
                              mediaTimeMs: 30_000),
                audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "transcribed", transcript: "My thought",
                cleanedTranscript: nil, displayText: nil, status: "active")]
            item.turns = [.init(id: "reply", sessionId: "session", role: "assistant", turnType: "assistant_response",
                                status: "complete", text: "Response", sourceInterjectionIds: ["margin"])]
            let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: "session")
            let margin = try XCTUnwrap(entries.first { $0.id == "session::margin" })
            let reply = try XCTUnwrap(entries.first { $0.id == "turn.reply" })
            XCTAssertNil(margin.precisePosition)
            XCTAssertEqual(margin.position, 20)
            XCTAssertEqual(reply.position, 20)
            XCTAssertEqual(entries.map(\.id), ["source.beginning", "session::margin", "turn.reply"])
        }
    }

    // MARK: #3862 one unit per item, matching its scrubber

    /// A podcast's publisher chapters are saved twice with one id: `chapters` (a percent) and `mediaChapters` (the exact start).
    private func podcastWithPublisherChapters(durationMs: Int = 6_180_000) -> ItemDetailState {
        var item = ItemDetailState(id: "podcast", title: "Episode", text: "", isNativeAudio: true)
        item.mediaDurationMs = durationMs
        item.chapters = [
            Chapter(id: "open", title: "Opening", startChar: 0, endChar: 0, percent: 0),
            Chapter(id: "long", title: "Self modification", startChar: 0, endChar: 0, percent: 65),
            Chapter(id: "rough", title: "Rough chapter", startChar: 0, endChar: 0, percent: 72)
        ]
        // "rough" has no exact twin: it was saved only as a fraction by an earlier build.
        item.mediaChapters = [
            MediaTimelineChapter(id: "open", title: "Opening", startMs: 0, transcriptSegmentId: "s0"),
            MediaTimelineChapter(id: "long", title: "Self modification", startMs: 4_050_000, transcriptSegmentId: "s1")
        ]
        return item
    }

    func testAPodcastChapterWithAnExactStartShowsItsTimeNotItsPercent() throws {
        let entries = ExperienceTimelineRailScreen.makeEntries(from: podcastWithPublisherChapters(), sessionID: nil)
        let long = try XCTUnwrap(entries.first { $0.id == "source.chapter.long" })
        XCTAssertEqual(long.cornerLabel, "1:07:30", "an hour in is 1:07:30, never 67:30")
        XCTAssertEqual(long.detail, "Chapter · 1:07:30")
        XCTAssertEqual(long.spokenPosition, "1 hour, 7 minutes, 30 seconds")
        XCTAssertEqual(long.position, 65, "the sort coordinate stays a percent, so the order does not move")
        let open = try XCTUnwrap(entries.first { $0.id == "source.chapter.open" })
        XCTAssertEqual(open.cornerLabel, "0:00")
        XCTAssertEqual(entries.map(\.id), ["source.chapter.open", "source.chapter.long", "source.chapter.rough"],
                       "showing a time does not move a card")
    }

    func testAPodcastChapterSavedOnlyAsAFractionSaysAboutAndNeverMakesATime() throws {
        let entries = ExperienceTimelineRailScreen.makeEntries(from: podcastWithPublisherChapters(), sessionID: nil)
        let rough = try XCTUnwrap(entries.first { $0.id == "source.chapter.rough" })
        XCTAssertEqual(rough.cornerLabel, "72%")
        XCTAssertEqual(rough.detail, "Chapter · about 72%")
        XCTAssertEqual(rough.spokenPosition, "72 percent")

        // An episode whose chapters an earlier build saved only as percents (no exact twins at all).
        var returning = podcastWithPublisherChapters()
        returning.mediaChapters = []
        for entry in ExperienceTimelineRailScreen.makeEntries(from: returning, sessionID: nil)
        where entry.id.hasPrefix("source.chapter.") {
            XCTAssertTrue(entry.cornerLabel.hasSuffix("%"), "\(entry.id) has no exact time to show")
            XCTAssertTrue(entry.detail.contains("about"), entry.detail)
        }
    }

    func testAnArticleKeepsPercentsEvenWhenItHasPreparedAudioChapters() throws {
        var item = ItemDetailState(id: "article", title: "Essay", text: String(repeating: "word ", count: 400))
        item.chapters = [Chapter(id: "c1", title: "Middle", startChar: 1_100, endChar: 1_500, percent: 56)]
        item.mediaChapters = [MediaTimelineChapter(id: "c1", title: "Middle", startMs: 502_000, transcriptSegmentId: "s")]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let chapter = try XCTUnwrap(entries.first { $0.id == "source.chapter.c1" })
        XCTAssertEqual(chapter.cornerLabel, "56%", "text never shows a time")
        XCTAssertEqual(chapter.detail, "Chapter · 56%")
        XCTAssertEqual(chapter.spokenPosition, "56 percent")
        XCTAssertEqual(try XCTUnwrap(entries.first { $0.id == "source.beginning" }).cornerLabel, "0%")
    }

    func testAMediaChapterAndSceneOverAnHourReadAsHoursInTheirDetailLines() throws {
        var item = ItemDetailState(id: "long", title: "Long episode", text: "", isNativeAudio: true)
        item.mediaDurationMs = 7_200_000
        item.mediaChapters = [MediaTimelineChapter(id: "m1", title: "Late", startMs: 4_050_000, transcriptSegmentId: "s")]
        item.listeningMapScenes = [MediaTimelineChapter(id: "sc1", title: "Scene", startMs: 3_725_000, transcriptSegmentId: "s")]
        let entries = ExperienceTimelineRailScreen.makeEntries(from: item, sessionID: nil)
        let chapter = try XCTUnwrap(entries.first { $0.id == "source.mediaChapter.m1" })
        XCTAssertEqual(chapter.detail, "Chapter · 1:07:30")
        XCTAssertEqual(chapter.cornerLabel, "1:07:30")
        let scene = try XCTUnwrap(entries.first { $0.id == "source.listeningMapScene.sc1" })
        XCTAssertTrue(scene.detail.hasPrefix("Generated scene · 1:02:05"), scene.detail)
        XCTAssertEqual(scene.cornerLabel, "1:02:05")
    }

    func testTheCurrentLineOnAPodcastHasTheClockAndTheFlooredPercent() throws {
        let item = podcastWithPublisherChapters(durationMs: 6_180_000)
        var snapshot = SessionSnapshot()
        snapshot.itemId = item.id
        snapshot.currentMediaTimeMs = 4_008_000
        snapshot.currentPlaybackDurationMs = 6_180_000
        let position = try XCTUnwrap(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
        XCTAssertEqual(position.line(for: "Current chapter"), "Current chapter · 1:06:48 · 64%")

        snapshot.currentMediaTimeMs = 6_130_000
        XCTAssertEqual(try XCTUnwrap(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
            .line(for: "Current chapter"), "Current chapter · 1:42:10 · 99%", "99% is not rounded up to finished")

        snapshot.currentPlaybackDurationMs = nil
        XCTAssertEqual(try XCTUnwrap(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
            .line(for: "Current chapter"), "Current chapter · 1:42:10", "no duration, no percent: none is made up")
    }

    func testTheCurrentLineOnAnArticleUsesTheTextScrubbersPercent() throws {
        let text = String(repeating: "word ", count: 200)
        let item = ItemDetailState(id: "article", title: "Essay", text: text)
        var snapshot = SessionSnapshot()
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.currentTextStart = 470
        let position = try XCTUnwrap(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
        let scrubber = TimelinePositionLabel.textScrubberPercent(offset: 470, length: text.count)
        XCTAssertEqual(position.percent, scrubber)
        XCTAssertEqual(position.line(for: "Current passage"), "Current passage · \(scrubber)%")
        XCTAssertNil(position.ms)
    }

    func testTheCurrentLineIsLeftOutWhenAnotherItemOrAReplyIsPlaying() {
        let item = ItemDetailState(id: "article", title: "Essay", text: String(repeating: "word ", count: 200))
        var snapshot = SessionSnapshot()
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.currentTextStart = 100
        snapshot.itemId = "another"
        XCTAssertNil(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.assistantTurnTTS.rawValue
        XCTAssertNil(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot),
                     "a reply counts characters in its own text, not the item's")
        snapshot.itemId = nil
        XCTAssertNil(ExperienceTimelineRailScreen.currentPosition(forItem: item, snapshot: snapshot))
    }
}
