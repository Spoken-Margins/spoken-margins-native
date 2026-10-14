import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #336: prepared audio for a PDF on the new reader is planned from what the player speaks,
/// not from `Item.text`, and its narration's timeline maps back into `Item.text`.
final class PreparedSpeechTextTests: XCTestCase {
    private let document = StructuredDocumentBuilder.build(lines: [
        StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
        StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
        StructuredDocumentLine(text: "Levels rose [12] as expected in every cohort we followed.", role: .body, pageIndex: 0),
        StructuredDocumentLine(text: "Participant Sessions P1 14", role: .table, pageIndex: 0),
        StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        StructuredDocumentLine(text: "[12] A. Author. A cited title. 2019.", role: .reference, pageIndex: 1),
        StructuredDocumentLine(text: "Journal of Examples 2", role: .pageFooter, pageIndex: 1),
        StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 1, level: 2),
        StructuredDocumentLine(text: "Supplementary methods are read aloud.", role: .body, pageIndex: 1),
    ], engine: "pdfkit_baseline", version: 2, pageCount: 2)

    private func paper(text: String? = nil) -> Item {
        Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: text ?? document.text, externalReference: nil, status: "ready")
    }

    func testANewReaderPDFIsPreparedFromItsListenableTextWithoutReferencesOrRunningHeads() throws {
        let item = paper()
        let prepared = try XCTUnwrap(PreparedSpeechText(item: item, document: document))
        XCTAssertEqual(prepared.itemText, item.text)
        XCTAssertEqual(prepared.text, StructuredDocumentSpeech.listenableText(document).text)
        for unheard in ["A cited title", "J Biol", "Journal of Examples", "P1 14", "[12]"] {
            XCTAssertTrue(item.text?.contains(unheard) == true, "precondition: Item.text keeps \(unheard)")
            XCTAssertFalse(prepared.text.contains(unheard), unheard)
        }
        XCTAssertTrue(prepared.text.contains("References skipped."))
        XCTAssertTrue(prepared.text.contains("Supplementary methods are read aloud."))
        XCTAssertNotEqual(NarrationChunkPlanner.identity(ofArticle: prepared.text),
                          NarrationChunkPlanner.identity(ofArticle: document.text),
                          "the prepared plan is identified by the listenable text, as the player's is")
    }

    func testEveryOtherItemIsPreparedFromItsOwnText() throws {
        let article = Item(id: "item-article", title: "Article", mediaType: "article", text: document.text, externalReference: nil, status: "ready")
        XCTAssertEqual(PreparedSpeechText(item: article, document: document)?.text, document.text, "only a PDF uses its document")
        XCTAssertEqual(PreparedSpeechText(item: paper(), document: nil)?.text, document.text, "a v1 PDF has no document")
        XCTAssertEqual(PreparedSpeechText(item: paper(text: "Other words."), document: document)?.text, "Other words.",
                       "a document that isn't exactly Item.text is not used")
        XCTAssertNil(PreparedSpeechText(item: paper(text: nil).withoutText, document: document))
        let plain = try XCTUnwrap(PreparedSpeechText(item: article, document: nil))
        XCTAssertEqual(plain.assemblyProjection(), SpeechTextNormalizer.normalizeWithSourceOffsets(document.text),
                       "an article's narration timeline is unchanged")
    }

    func testAssembledNarrationMapsEachPassageBackToItsPlaceInItemText() throws {
        let item = paper()
        let itemText = try XCTUnwrap(item.text)
        let prepared = try XCTUnwrap(PreparedSpeechText(item: item, document: document))
        let projection = prepared.assemblyProjection()
        XCTAssertEqual(projection.text, SpeechTextNormalizer.normalize(prepared.text), "chunks start in the normalized listenable text")
        XCTAssertEqual(projection.sourceLength, itemText.count)
        for passage in ["Levels rose", "Appendix", "Supplementary methods"] {
            let spoken = projection.text.distance(from: projection.text.startIndex, to: try XCTUnwrap(projection.text.range(of: passage)).lowerBound)
            let source = itemText.distance(from: itemText.startIndex, to: try XCTUnwrap(itemText.range(of: passage)).lowerBound)
            XCTAssertEqual(projection.sourceOffset(atSpokenCharacterOffset: spoken), source, passage)
        }
        XCTAssertEqual(projection.sourceOffset(atSpokenCharacterOffset: projection.text.count), itemText.count, "the end is Item.text's end")
        XCTAssertEqual(projection.sourceOffsets, projection.sourceOffsets.sorted(), "positions never run backwards")
    }

    func testTheCacheReadsTheStoredDocumentAndFollowsAChangedText() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let item = paper()
        try store.saveItem(item)
        try store.saveStructuredDocument(document, itemId: item.id)
        let cache = PreparedSpeechTextCache()

        let first = try XCTUnwrap(cache.resolve(item: try store.loadItem(id: item.id), documents: store))
        XCTAssertEqual(first.text, StructuredDocumentSpeech.listenableText(document).text)
        XCTAssertEqual(cache.resolve(item: item, documents: nil), first, "the same text reuses the entry")

        let later = Item(id: "item-later", title: "Later", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        try store.saveItem(later)
        XCTAssertEqual(cache.resolve(item: later, documents: store)?.text, document.text, "no document yet: Item.text")
        try store.saveStructuredDocument(document, itemId: later.id)
        XCTAssertEqual(cache.resolve(item: later, documents: store)?.text, first.text, "a document saved later is used")

        let changed = paper(text: "A re-imported text with no document of its own.")
        XCTAssertEqual(cache.resolve(item: changed, documents: store)?.text, changed.text, "a changed Item.text isn't served the old entry")
        XCTAssertNil(cache.resolve(item: paper(text: nil).withoutText, documents: store))
    }
    func testInvalidationFindsNewRolesWhenCanonicalTextDidNotChange() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "speech-cache-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        let body = StructuredDocumentBuilder.build(lines: [.init(text: "Words whose role changed.", role: .body, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let reference = StructuredDocumentBuilder.build(lines: [.init(text: "Words whose role changed.", role: .reference, pageIndex: 0)], engine: "pdfkit_baseline", version: 2, pageCount: 1)
        let item = paper(text: body.text)
        try store.saveItem(item)
        try store.saveStructuredDocument(body, itemId: item.id)
        let cache = PreparedSpeechTextCache()
        XCTAssertEqual(cache.resolve(item: item, documents: store)?.text, body.text)
        try store.saveStructuredDocument(reference, itemId: item.id)
        XCTAssertEqual(reference.text, body.text)
        XCTAssertEqual(cache.resolve(item: item, documents: store)?.text, body.text, "negative control: text equality retains the old entry")
        cache.invalidate(itemId: item.id)
        XCTAssertEqual(cache.resolve(item: item, documents: store)?.text, "References skipped.", "reference content must leave the speech projection")
    }

}

private extension Item {
    var withoutText: Item {
        var copy = self
        copy.text = nil
        return copy
    }
}
