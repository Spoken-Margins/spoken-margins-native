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
}
