import XCTest
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    func testOpeningAnItemLoadsAuthoredSourceRolesIntoTheTimeline() throws {
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
        let source = entries.compactMap { entry -> TimelineSourceContent.Entry? in
            guard case .sourceText(let source) = entry.action else { return nil }
            XCTAssertTrue(entry.accessibilityIdentifier.hasPrefix("timeline.sourceText."))
            return source
        }
        XCTAssertEqual(source.map(\.text), ["Caption", "Cell A | Cell B", "A footnote"])
        XCTAssertEqual(source.map(\.role), [.caption, .table, .footnote])
        XCTAssertEqual(source.map(\.pageIndex), [0, 0, 1])
        XCTAssertEqual(source.first?.label, "Figure 1: authored label")

        model.openItem(id: "podcast")
        XCTAssertTrue(model.selectedItem.isNativeAudio)
        XCTAssertTrue(model.selectedItem.timelineSource.entries.isEmpty,
                      "An audio transcript must not become source text without time mapping")
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
            case .sourceText(let source): source.start == 13
            default: false
            }
        }
        XCTAssertEqual(relevant.map(\.position), [1, 1, 1, 1])
        XCTAssertEqual(relevant.count, 4)
        for (entry, expected) in zip(relevant, [1.1, 1.1, 1.2, 1.3]) {
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
