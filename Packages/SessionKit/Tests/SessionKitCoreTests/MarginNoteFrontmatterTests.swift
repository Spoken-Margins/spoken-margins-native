import Foundation
import XCTest
@testable import SessionKit

/// The Margin note's YAML properties block (#491): Obsidian reads it, so it must parse and
/// round-trip every value, say whether the Margin is on the source or on an AI reply, and
/// never carry a private feed link.
final class MarginNoteFrontmatterTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    func testPodcastMarginNoteStartsWithParsableProperties() throws {
        let item = Item(
            id: "item-podcast", title: "Episode 12", mediaType: "audio", text: nil,
            externalReference: "https://example.com/episodes/12", status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: "https://cdn.example.com/12.mp3", durationMs: 3_600_000),
            author: "The Show"
        )
        let note = try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 754_000))
        let properties = try FrontmatterParser.parse(note)

        XCTAssertEqual(properties["title"], .string("Episode 12"))
        XCTAssertEqual(properties["source"], .string("https://example.com/episodes/12"))
        XCTAssertEqual(properties["author"], .string("The Show"))
        XCTAssertEqual(properties["created"], .plain("2026-04-24T03:06:40Z"))
        XCTAssertEqual(properties["item_id"], .string("item-podcast"))
        XCTAssertEqual(properties["margin_id"], .string("margin"))
        XCTAssertEqual(properties["margin_kind"], .plain("spoken"))
        XCTAssertEqual(properties["target"], .plain("source"))
        XCTAssertEqual(properties["tags"], .list(["spoken-margins"]))
        XCTAssertEqual(Array(properties.keys).sorted(), ["author", "created", "item_id", "margin_id", "margin_kind", "source", "tags", "target", "title"])
        XCTAssertTrue(note.contains("Position: 754000 ms"))
    }

    func testArticleMarginWithoutAuthorOmitsAuthorAndMarksWrittenKind() throws {
        let item = Item(id: "item-article", title: "An essay", mediaType: "text", text: "Source text.",
                        externalReference: "https://example.com/essay", status: "ready")
        let note = try renderNote(item: item, margin: margin(item: item, kind: .written, mediaTimeMs: nil))
        let properties = try FrontmatterParser.parse(note)

        XCTAssertNil(properties["author"])
        XCTAssertEqual(properties["source"], .string("https://example.com/essay"))
        XCTAssertEqual(properties["margin_kind"], .plain("written"))
        XCTAssertEqual(properties["target"], .plain("source"))
    }

    func testAIReplyMarginSaysSoAndDoesNotShowASourcePosition() throws {
        let item = Item(id: "item-ai", title: "Talk", mediaType: "text", text: "Source text.",
                        externalReference: "https://example.com/talk", status: "ready")
        var onReply = margin(item: item, kind: nil, mediaTimeMs: nil)
        onReply.targetType = .assistantTurn
        onReply.targetId = "turn-1"
        onReply.roughPercent = 40
        let note = try renderNote(item: item, margin: onReply)
        let properties = try FrontmatterParser.parse(note)

        XCTAssertEqual(properties["target"], .plain("ai_reply"))
        XCTAssertFalse(note.contains("\nPosition: "), note)
        XCTAssertTrue(note.contains("Position in AI reply: 40%"), note)
    }

    func testTitlesAndAuthorsWithColonsQuotesAndNewlinesRoundTrip() throws {
        let awkward = [
            "Why: the \"real\" answer",
            "Line one\nkey: injected",
            "Back\\slash # not a comment",
            "- starts like a list",
            "Tab\there, carriage\rreturn, and \u{2028} separator",
            "---",
            "",
        ]
        for title in awkward {
            let item = Item(id: "item: \"x\"", title: title, mediaType: "text", text: "Source.",
                            externalReference: nil, status: "ready", author: "O'Brien: \"Q\"\nSecond line")
            let note = try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: nil))
            let properties = try FrontmatterParser.parse(note)
            XCTAssertEqual(properties["title"], .string(title), note)
            XCTAssertEqual(properties["author"], .string("O'Brien: \"Q\"\nSecond line"))
            XCTAssertEqual(properties["item_id"], .string("item: \"x\""))
            XCTAssertNil(properties["key"], "A newline in a title must not add a property")
        }
    }

    func testPrivateFeedLinksNeverReachTheNote() throws {
        let privateLink = "https://www.patreon.com/rss/show?auth=abc123SECRET456def789ghi012jkl345"
        let privateMedia = "https://c10.patreonusercontent.com/episode.mp3?token-hash=zyx987SECRET654wvu321tsr098qpo765"
        let item = Item(
            id: "item-private", title: "Members episode", mediaType: "audio", text: nil,
            externalReference: privateLink, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: privateMedia),
            author: "Paid Show"
        )
        let note = try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 1_000))
        let properties = try FrontmatterParser.parse(note)

        XCTAssertNil(properties["source"])
        XCTAssertFalse(note.contains("patreon"), note)
        XCTAssertFalse(note.contains("SECRET"), note)

        // A hand-built export that skipped the engine's filter is still cleaned.
        var export = try buildExport(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 1_000))
        export.item.externalReference = privateLink
        export.item.sourceURL = privateMedia
        let frontmatter = MarginNoteFrontmatter(export: export, margin: export.interjections[0], created: "x")
        XCTAssertNil(frontmatter.source)
    }

    func testBodyBelowTheBlockIsTheBuild29Note() throws {
        let item = Item(id: "item-body", title: "Body", mediaType: "text", text: "Source.",
                        externalReference: "https://example.com/body", status: "ready")
        let note = try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: nil))
        let body = try XCTUnwrap(note.components(separatedBy: "\n---\n\n").dropFirst().first)
        XCTAssertEqual(body, """
        # Body

        Created: 2026-04-24T03:06:40Z
        Source: https://example.com/body
        Target: item / item-body
        Session: session-item-body
        Margin: margin
        Position: 0%

        ## Listener Margin

        A thought.

        ## Context before

        Before.

        ## Context after

        After.

        """)
    }

    // MARK: - Fixtures

    private func margin(item: Item, kind: InterjectionCaptureKind?, mediaTimeMs: Int?) -> Interjection {
        Interjection(
            id: "margin", itemId: item.id, sessionId: "session-" + item.id, targetType: .item, targetId: item.id,
            createdAt: createdAt, roughPercent: 0,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: 0, endChar: 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: kind == .written ? "discarded" : "saved",
            transcriptionStatus: "transcribed", transcript: "A thought.", cleanedTranscript: nil,
            displayText: "A thought.", status: "active", captureKind: kind
        )
    }

    private func buildExport(item: Item, margin: Interjection) throws -> SessionExport {
        let session = Session(id: margin.sessionId, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: item.id,
                              position: Position(), completionPercent: 0, playbackRate: 1)
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session], interjections: [margin.id: margin]
        )
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: repository
        )
        // The same options the notes-folder gatherer uses.
        return try engine.buildExport(options: ExportOptions(
            sessionId: session.id,
            includeFullText: false, includeReference: true, includeListeningMap: false,
            includeInterjections: true, includeTurns: false,
            scope: "selected_interjections", interjectionIds: [margin.id]
        ))
    }

    private func renderNote(item: Item, margin: Interjection) throws -> String {
        let note = SessionExportMarkdownRenderer.renderMargin(try buildExport(item: item, margin: margin), createdAt: createdAt)
        XCTAssertFalse(note.isEmpty)
        return note
    }
}

/// A strict reader for the subset of YAML the note writes: `---`, then `key: value` lines where the
/// value is a double-quoted scalar, a `[a, b]` flow list of plain words, or a plain word, then `---`.
/// Anything else fails the test, so a stray line break or unescaped quote can't pass unnoticed.
enum FrontmatterParser {
    enum Value: Equatable { case string(String), plain(String), list([String]) }
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func parse(_ note: String) throws -> [String: Value] {
        let lines = note.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw Failure(description: "No frontmatter block in:\n\(note)")
        }
        guard lines.count > end + 1, lines[end + 1].isEmpty else {
            throw Failure(description: "No blank line after the block")
        }
        var result: [String: Value] = [:]
        for line in lines[1..<end] {
            guard let colon = line.range(of: ": ") else { throw Failure(description: "Not a property: \(line)") }
            let key = String(line[..<colon.lowerBound])
            guard key.range(of: "^[a-z_]+$", options: .regularExpression) != nil, result[key] == nil else {
                throw Failure(description: "Bad or repeated key: \(key)")
            }
            result[key] = try value(String(line[colon.upperBound...]))
        }
        return result
    }

    private static func value(_ raw: String) throws -> Value {
        if raw.hasPrefix("\"") { return .string(try unquote(raw)) }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let words = raw.dropFirst().dropLast().components(separatedBy: ", ")
            guard words.allSatisfy(isPlain) else { throw Failure(description: "Bad list: \(raw)") }
            return .list(words)
        }
        guard isPlain(raw) else { throw Failure(description: "Unsafe plain value: \(raw)") }
        return .plain(raw)
    }

    private static func isPlain(_ word: String) -> Bool {
        word.range(of: "^[A-Za-z0-9][A-Za-z0-9_:.-]*$", options: .regularExpression) != nil
    }

    private static func unquote(_ raw: String) throws -> String {
        var scalars = Array(raw.unicodeScalars.dropFirst())
        var out = String.UnicodeScalarView()
        while let scalar = scalars.first {
            scalars.removeFirst()
            switch scalar {
            case "\"":
                guard scalars.isEmpty else { throw Failure(description: "Text after closing quote: \(raw)") }
                return String(out)
            case "\\":
                guard let escape = scalars.first else { break }
                scalars.removeFirst()
                switch escape {
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard scalars.count >= 4, let code = UInt32(String(String.UnicodeScalarView(scalars.prefix(4))), radix: 16),
                          let decoded = Unicode.Scalar(code) else { throw Failure(description: "Bad \\u escape: \(raw)") }
                    scalars.removeFirst(4)
                    out.append(decoded)
                default: throw Failure(description: "Unknown escape \\\(escape): \(raw)")
                }
            case _ where scalar.value < 0x20 || [0x7F, 0x85, 0x2028, 0x2029, 0xFEFF].contains(scalar.value):
                throw Failure(description: "Unescaped control character in: \(raw)")
            default:
                out.append(scalar)
            }
        }
        throw Failure(description: "Unterminated quoted value: \(raw)")
    }
}
