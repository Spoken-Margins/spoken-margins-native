import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// What a play of a long PDF costs on the main thread when the listener never opened it first (#4223, #2256 item 3,
/// piece 5 of docs/design/main-thread-boundary.md). Opening a PDF builds its listenable text off the main thread and
/// the engine keeps it; a play from a Library row, a widget or a chapter jump has no such open, so
/// `SessionEngine.startSession` loads the item, reads the structured document and builds the text itself, on main.
///
/// The fixture is generated here (a 300-page document of made-up prose in the roles a paper or book has), written to a
/// real SQLite file, and played by a fresh engine each run, so nothing was kept from an earlier open. The player is a
/// fake that does the speech normalisation the real one does, because `AVAudioSession` does not exist on macOS or
/// Linux. Set `SESSIONKIT_START_COST=1` to print the table for a PR; a normal run builds a smaller fixture and only
/// checks that the numbers it would print are real.
final class PDFStartCostTests: XCTestCase {
    private var fixtures: [LibraryFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
        SpeechTextNormalizer.projectionMemo.forget()
    }

    private static let profile = RuntimeCapabilityProfile(
        id: "phone", displayName: "Phone",
        capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts", "native_media"], "timeline": ["chapter_timing"]])

    /// Does what the app's speech player does with the text it is handed, and records it.
    private final class NormalizingSpeech: AudioPlaybackClient {
        var prepared = ""
        func prepareSpeechText(_ text: String) throws -> String {
            prepared = SpeechTextNormalizer.normalizeWithSourceOffsets(text).text
            return prepared
        }
        func play(targetId: String) throws {}
        func play(targetId: String, from charOffset: Int) throws {}
        func pause() throws {}
    }

    private func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let elapsed = try ContinuousClock().measure(body)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// A paper-shaped document: a running header and footer on every page, about 3,000 characters of body in six
    /// paragraphs per page, a heading every ten pages, a footnote with a superscript marker, a table and an equation
    /// now and then, and a reference list at the end. 300 pages come to about 0.8 million characters, which is a long
    /// book, not a 20-page paper.
    static func document(pages: Int) -> StructuredDocument {
        let sentence = "The committee reviewed the figures for the quarter and found that revenue rose by 12.5 percent. "
        func paragraph(_ seed: Int) -> String {
            var text = ""
            var index = 0
            while text.count < 500 { text += sentence.replacingOccurrences(of: "12.5", with: "\(seed % 90 + index).5"); index += 1 }
            // A link in one paragraph in four, as an article has them, not in every sentence.
            if seed % 4 == 0 { text += "See https://example.com/report/\(seed) for the table." }
            return text.trimmingCharacters(in: .whitespaces)
        }
        var lines: [StructuredDocumentLine] = [StructuredDocumentLine(text: "A Long Report on Quarterly Figures", role: .title, pageIndex: 0)]
        for page in 0..<pages {
            lines.append(StructuredDocumentLine(text: "Quarterly Figures", role: .pageHeader, pageIndex: page))
            if page % 10 == 0 {
                lines.append(StructuredDocumentLine(text: "Chapter \(page / 10 + 1). What the committee found", role: .heading, pageIndex: page, level: 1))
            }
            for line in 0..<6 {
                let body = paragraph(page * 6 + line)
                // A citation marker: the last two characters of every third paragraph are printed as a superscript.
                let marked = line % 3 == 0 ? [(body.count - 2)..<body.count] : []
                lines.append(StructuredDocumentLine(text: body, role: .body, pageIndex: page, superscripts: marked))
            }
            if page % 7 == 0 { lines.append(StructuredDocumentLine(text: "1 A footnote that explains where the figure came from.", role: .footnote, pageIndex: page)) }
            if page % 25 == 0 { lines.append(StructuredDocumentLine(text: "Table 1. Revenue by quarter 12 14 16 18", role: .table, pageIndex: page)) }
            if page % 40 == 0 { lines.append(StructuredDocumentLine(text: "x = (a + b) / c", role: .equation, pageIndex: page)) }
            lines.append(StructuredDocumentLine(text: "Page \(page + 1)", role: .pageFooter, pageIndex: page))
        }
        for reference in 1...200 {
            lines.append(StructuredDocumentLine(text: "[\(reference)] A. Author. A paper on quarterly figures. Journal of Figures, \(1990 + reference % 30).", role: .reference, pageIndex: pages - 1))
        }
        return StructuredDocumentBuilder.build(lines: lines, engine: "pdfkit_structured", version: 2, pageCount: pages)
    }

    /// Prints the table for the PR. A normal run uses a 12-page document and prints nothing but a check.
    func testTheStartOfALongPDFPlayedWithNoOpen() throws {
        let printsTable = ProcessInfo.processInfo.environment["SESSIONKIT_START_COST"] == "1"
        let pages = printsTable ? 300 : 12
        let fixture = try LibraryFixture.build(.small)
        fixtures.append(fixture)
        let meter = StoreReadMeter()
        let store = try fixture.openStore(meter: meter)

        let document = Self.document(pages: pages)
        let itemId = "item-long-pdf"
        try store.saveItem(Item(
            id: itemId, title: "A Long Report", mediaType: "pdf", text: document.text,
            externalReference: nil, status: "ready"))
        try store.saveStructuredDocument(document, itemId: itemId)
        XCTAssertEqual(document.extraction.pageCount, pages)
        XCTAssertEqual(Set(document.segments.filter { $0.role == .body }.compactMap(\.pageIndex)).count, pages, "every page carries body text")

        var summary: [Double] = [], loadDocument: [Double] = [], build: [Double] = [], start: [Double] = []
        var firstStart = 0.0, spoken = "", startReads = 0, startRows = 0
        let runs = 7
        for run in 0..<runs {
            SpeechTextNormalizer.projectionMemo.forget() // a play with no open: no earlier projection of this text
            // `prepareSourceMediaPlayback`'s own store read for a PDF (the rest of it is the offline-asset coordinator,
            // which only exists in the app and returns at its guard for a PDF that has no download).
            let summaryMs = try milliseconds { _ = try store.loadItemSummary(id: itemId) }
            var loaded: StructuredDocument?
            let loadMs = try milliseconds { loaded = try store.loadStructuredDocument(itemId: itemId) }
            let item = try XCTUnwrap(try store.loadItem(id: itemId))
            let buildMs = milliseconds { _ = StructuredDocumentSpeech.listenableProjection(item: item, document: loaded) }

            SpeechTextNormalizer.projectionMemo.forget()
            let speech = NormalizingSpeech()
            let engine = SessionEngine(profile: Self.profile, repository: store, audio: speech)
            meter.reset()
            let elapsed = try milliseconds { _ = try engine.startSession(itemId: itemId) }
            let totals = meter.totals().values
            spoken = speech.prepared
            _ = try engine.endSession()
            guard run > 0 else { firstStart = elapsed; continue } // the first run fills SQLite's page cache: no median counts it
            summary.append(summaryMs); loadDocument.append(loadMs); build.append(buildMs); start.append(elapsed)
            startReads = totals.reduce(0) { $0 + $1.calls }; startRows = totals.reduce(0) { $0 + $1.rows }
        }

        // The start must have handed the player the document's listenable text, not item.text (which `try?` falls back
        // to when the document fails to load or does not match): only the projection announces what it skips and drops
        // the running footer. A start that took the fallback measures the wrong path.
        XCTAssertTrue(spoken.contains("Equation not read."), "the structured document's listenable text reached the player")
        XCTAssertTrue(spoken.contains("References skipped."))
        XCTAssertFalse(spoken.contains("Page \(pages)"), "the running footer is not read")
        XCTAssertGreaterThan(startReads, 0)
        if printsTable {
            print("PDF-START-COST \(pages) pages, \(document.text.count) characters, \(document.segments.count) segments: loadItemSummary \(median(summary)) ms, loadStructuredDocument \(median(loadDocument)) ms, listenable text build \(median(build)) ms, whole startSession (fresh engine, no open) first \(firstStart) ms, median \(median(start)) ms, worst \(start.max() ?? 0) ms (\(startReads) reads, \(startRows) rows), spoken characters \(spoken.count)")
        }
    }
}
