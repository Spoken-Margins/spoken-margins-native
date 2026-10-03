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
        XCTAssertTrue(note.contains("\nPosition: 12:34\n"), note)
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

    /// Build 29's body plus the clock position and the link back (#171); the writer rewrites unedited notes once.
    func testBodyBelowTheBlock() throws {
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
        [Open this Margin in Spoken Margins](spokenmargins://margin?session=session-item-body&margin=margin)

        ## Listener Margin

        A thought.

        ## Context before

        Before.

        ## Context after

        After.

        """)
    }

    // MARK: - Every spoken Margin, with a way back (#171)

    func testMediaPositionsReadAsAClock() throws {
        let item = Item(id: "item-long", title: "Long episode", mediaType: "audio", text: nil,
                        externalReference: "https://example.com/long", status: "ready")
        XCTAssertTrue(try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 65_400)).contains("\nPosition: 01:05\n"))
        XCTAssertTrue(try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 3_723_999)).contains("\nPosition: 1:02:03\n"))
        XCTAssertEqual(MarginDeepLink.clockPosition(ms: 0), "00:00")
        XCTAssertEqual(MarginDeepLink.clockPosition(ms: -5), "00:00")
    }

    func testTheNoteLinksBackToItsOwnMargin() throws {
        let item = Item(id: "item-link", title: "Linked", mediaType: "audio", text: nil,
                        externalReference: "https://example.com/linked", status: "ready")
        let note = try renderNote(item: item, margin: margin(item: item, kind: nil, mediaTimeMs: 1_000))
        let line = try XCTUnwrap(note.components(separatedBy: "\n").first { $0.hasPrefix("[Open this Margin in Spoken Margins](") })
        let link = try XCTUnwrap(MarginDeepLink(url: try XCTUnwrap(URL(string: String(line.dropFirst("[Open this Margin in Spoken Margins](".count).dropLast())))))
        XCTAssertEqual(link, MarginDeepLink(sessionId: "session-item-link", marginId: "margin"))
    }

    func testSpokenMarginWithoutATranscriptStillGetsANoteThatSaysSo() throws {
        let item = Item(id: "item-untranscribed", title: "Untranscribed", mediaType: "audio", text: nil,
                        externalReference: "https://example.com/u", status: "ready")
        var spoken = margin(item: item, kind: .audio, mediaTimeMs: 2_000)
        spoken.transcript = nil
        spoken.displayText = nil
        spoken.transcriptionStatus = "failed"
        let note = try renderNote(item: item, margin: spoken)
        XCTAssertTrue(note.contains("## Listener Margin\n\nTranscript not available yet.\n"), note)
        XCTAssertTrue(SessionExportMarkdownRenderer.writesMarginNote(captureKind: .audio, text: nil))
        XCTAssertTrue(SessionExportMarkdownRenderer.writesMarginNote(captureKind: nil, text: "  "))

        // When the transcript arrives, the same note id renders the words instead.
        spoken.transcript = "Arrived later."
        spoken.transcriptionStatus = "transcribed"
        XCTAssertTrue(try renderNote(item: item, margin: spoken).contains("## Listener Margin\n\nArrived later.\n"))
    }

    func testAWrittenMarginWithNoWordsGetsNoNote() {
        XCTAssertFalse(SessionExportMarkdownRenderer.writesMarginNote(captureKind: .written, text: " \n"))
        XCTAssertTrue(SessionExportMarkdownRenderer.writesMarginNote(captureKind: .written, text: "Words."))
    }

    // MARK: - A paper's citation (#206)

    func testPaperMarginCarriesDOIAuthorsYearAndThePageItSitsOn() throws {
        let (item, document) = paper(bibliography: PDFBibliography(
            doi: "10.1145/3613904.3642123", arxivId: "2607.28282",
            authors: ["Ada Lovelace", "Babbage, \"Charles\""], year: 2024, title: "Listening"
        ))
        let onPageTwo = margin(item: item, kind: .written, mediaTimeMs: nil, startChar: 20)
        let note = try renderNote(item: item, margin: onPageTwo, document: document)
        let properties = try FrontmatterParser.parse(note)

        XCTAssertEqual(properties["title"], .string("A Paper"))
        XCTAssertEqual(properties["doi"], .string("10.1145/3613904.3642123"))
        XCTAssertEqual(properties["arxiv_id"], .string("2607.28282"))
        XCTAssertEqual(properties["authors"], .strings(["Ada Lovelace", "Babbage, \"Charles\""]))
        XCTAssertEqual(properties["year"], .plain("2024"))
        XCTAssertEqual(properties["page"], .plain("2"))
        // Imported from Files, so the paper's DOI page is its source.
        XCTAssertEqual(properties["source"], .string("https://doi.org/10.1145/3613904.3642123"))
        XCTAssertEqual(Array(properties.keys).sorted(), [
            "arxiv_id", "authors", "created", "doi", "item_id", "margin_id", "margin_kind", "page", "source", "tags",
            "target", "title", "year",
        ])

        let onPageOne = try renderNote(item: item, margin: margin(item: item, kind: .written, mediaTimeMs: nil, startChar: 7), document: document)
        XCTAssertEqual(try FrontmatterParser.parse(onPageOne)["page"], .plain("1"))
    }

    func testArXivPaperWithoutMetadataLinksToItsAbstractPage() throws {
        let (item, document) = paper(bibliography: PDFBibliography(arxivId: "hep-th/9901001"))
        let note = try renderNote(item: item, margin: margin(item: item, kind: .written, mediaTimeMs: nil, startChar: 0), document: document)
        let properties = try FrontmatterParser.parse(note)

        XCTAssertEqual(properties["source"], .string("https://arxiv.org/abs/hep-th/9901001"))
        XCTAssertNil(properties["doi"])
        XCTAssertNil(properties["authors"])
        XCTAssertNil(properties["year"])
        XCTAssertEqual(properties["page"], .plain("1"))
    }

    func testPaperWithoutABibliographyKeepsTheNoteItHadBefore() throws {
        let (item, document) = paper(bibliography: nil)
        let note = try renderNote(item: item, margin: margin(item: item, kind: .written, mediaTimeMs: nil, startChar: 20), document: document)
        XCTAssertTrue(note.hasPrefix("""
        ---
        title: "A Paper"
        created: 2026-04-24T03:06:40Z
        item_id: "item-paper"
        margin_id: "margin"
        margin_kind: written
        target: source
        tags: [spoken-margins]
        ---

        # A Paper

        """), note)
        let export = try buildExport(item: item, margin: margin(item: item, kind: .written, mediaTimeMs: nil, startChar: 20), document: document)
        let json = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertFalse(json.contains("bibliography"), json)
        XCTAssertFalse(json.contains("\"page\""), json)
    }

    // MARK: - Fixtures

    private func paper(bibliography: PDFBibliography?) -> (Item, StructuredDocument) {
        let document = StructuredDocument(
            extraction: .init(engine: "pdfkit", version: 2, sourceSHA256: nil, pageCount: 2, textSHA256: nil),
            text: "A Paper\nFirst page.\nSecond page.",
            segments: [
                .init(id: "s0", role: .title, range: .init(start: 0, length: 7), pageIndex: 0),
                .init(id: "s1", role: .body, range: .init(start: 8, length: 11), pageIndex: 0),
                .init(id: "s2", role: .body, range: .init(start: 20, length: 12), pageIndex: 1),
            ],
            markers: []
        )
        let item = Item(
            id: "item-paper", title: "A Paper", mediaType: "pdf", text: document.text,
            externalReference: "a-paper.pdf", status: "ready", externalReferenceType: "file",
            documentStructure: PDFDocumentStructure(
                extractionEngine: .pdfKit, analysisStatus: .partial, pageCount: 2, analyzedPageCount: 0,
                bibliography: bibliography
            )
        )
        return (item, document)
    }

    /// #560: a Margin on a Wikipedia article imported before the fix captured link titles in its
    /// context; the note shows the context as read (the stored anchor isn't touched).
    func testNoteContextFromAnEarlierWikipediaImportDropsLinkTitles() throws {
        let stored = LinkTitleSpeechTests.storedBeforeFix
        let item = Item(id: "item-wiki", title: "Marginalia", mediaType: "text", text: stored + " Next sentence.",
                        externalReference: "https://en.wikipedia.org/wiki/Marginalia", status: "ready")
        var onWiki = margin(item: item, kind: .written, mediaTimeMs: nil)
        onWiki.anchor.anchorBefore = stored
        onWiki.anchor.anchorAfter = "of a [book]( \"Book\") or other document."
        let note = try renderNote(item: item, margin: onWiki)

        XCTAssertTrue(note.contains("## Context before\n\n" + LinkTitleSpeechTests.storedAsNowRead + "\n"), note)
        XCTAssertTrue(note.contains("## Context after\n\nof a book or other document.\n"), note)
    }

    private func margin(item: Item, kind: InterjectionCaptureKind?, mediaTimeMs: Int?, startChar: Int = 0) -> Interjection {
        Interjection(
            id: "margin", itemId: item.id, sessionId: "session-" + item.id, targetType: .item, targetId: item.id,
            createdAt: createdAt, roughPercent: 0,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar + 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: kind == .written ? "discarded" : "saved",
            transcriptionStatus: "transcribed", transcript: "A thought.", cleanedTranscript: nil,
            displayText: "A thought.", status: "active", captureKind: kind
        )
    }

    private func buildExport(item: Item, margin: Interjection, document: StructuredDocument? = nil) throws -> SessionExport {
        let session = Session(id: margin.sessionId, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: item.id,
                              position: Position(), completionPercent: 0, playbackRate: 1)
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session], interjections: [margin.id: margin]
        )
        if let document { try repository.saveStructuredDocument(document, itemId: item.id) }
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

    private func renderNote(item: Item, margin: Interjection, document: StructuredDocument? = nil) throws -> String {
        let note = SessionExportMarkdownRenderer.renderMargin(try buildExport(item: item, margin: margin, document: document), createdAt: createdAt)
        XCTAssertFalse(note.isEmpty)
        return note
    }
}

/// A strict reader for the subset of YAML the note writes: `---`, then `key: value` lines where the
/// value is a double-quoted scalar, a `[a, b]` flow list of plain words or of double-quoted scalars,
/// or a plain word, then `---`. Anything else fails the test, so a stray line break or unescaped
/// quote can't pass unnoticed.
enum FrontmatterParser {
    enum Value: Equatable { case string(String), plain(String), list([String]), strings([String]) }
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
        if raw.hasPrefix("[\""), raw.hasSuffix("]") { return .strings(try quotedList(raw)) }
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

    /// `["a", "b, c"]`: each item is a double-quoted scalar, items separated by `, `.
    private static func quotedList(_ raw: String) throws -> [String] {
        var rest = Substring(raw.dropFirst())
        var items: [String] = []
        while true {
            guard rest.hasPrefix("\"") else { throw Failure(description: "Bad list item in: \(raw)") }
            var end = rest.index(after: rest.startIndex)
            while end < rest.endIndex, rest[end] != "\"" {
                end = rest[end] == "\\" ? rest.index(end, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex : rest.index(after: end)
            }
            guard end < rest.endIndex else { throw Failure(description: "Unterminated list item in: \(raw)") }
            items.append(try unquote(String(rest[...end])))
            rest = rest[rest.index(after: end)...]
            if rest == "]" { return items }
            guard rest.hasPrefix(", ") else { throw Failure(description: "Bad list separator in: \(raw)") }
            rest = rest.dropFirst(2)
        }
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
