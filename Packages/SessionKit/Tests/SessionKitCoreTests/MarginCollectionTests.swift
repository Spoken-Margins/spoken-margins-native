import XCTest
import SessionKit
import SessionKitTestInputs

final class MarginCollectionTests: XCTestCase {
    func testDeletedItemsAndMissingItemsHidePrivateAndSharedMargins() throws {
        let entries = try MarginCollection.build(
            items: [item("live"), item("deleted", deleted: true)],
            sessions: [session("live", itemID: "live"), session("deleted", itemID: "deleted"), session("missing", itemID: "missing")],
            loadInterjections: { id in
                XCTAssertEqual(id, "live", "Excluded sessions must not be read")
                return [self.note("note", sessionID: id)]
            },
            loadImportedLayers: { [self.layer("live", itemID: "live"), self.layer("deleted", itemID: "deleted"), self.layer("missing", itemID: "missing")] },
            loadImportedInterjections: { id in
                XCTAssertEqual(id, "live", "Excluded layers must not be read")
                return [self.sharedNote("note", layerID: id)]
            }
        )
        XCTAssertEqual(entries.privateRows.map(\.id), ["live::note"])
        XCTAssertEqual(entries.sharedRows.map(\.id), ["shared::live::note"])
        XCTAssertEqual(entries.privateRows.first?.itemTitle, "Title live")
        XCTAssertEqual(entries.sharedRows.first?.itemTitle, "Title live")
    }

    func testOnlyActivePrivateInterjectionsAppear() throws {
        let entries = try build(notes: [note("active"), note("deleted", status: "deleted"), note("pending", status: "pending"), note("empty", status: ""), note("case", status: "Active")])
        XCTAssertEqual(entries.privateRows.map(\.interjection.id), ["active"])
    }

    func testPrivateSortUsesSessionDateThenCreatedDateThenFullIdentity() throws {
        let sessions = [session("undated"), session("created", created: 20), session("updated", created: 1, updated: 30), session("b", created: 10), session("a", created: 10)]
        let entries = try MarginCollection.build(items: [item()], sessions: sessions, loadInterjections: { id in
            if id == "updated" { return [self.note("older", sessionID: id, created: 1), self.note("newer", sessionID: id, created: 2)] }
            if id == "a" { return [self.note("z", sessionID: id), self.note("a", sessionID: id)] }
            return [self.note("a", sessionID: id, created: id == "undated" ? 999 : 10)]
        }, loadImportedLayers: { [] }, loadImportedInterjections: { _ in [] })
        XCTAssertEqual(entries.privateRows.map(\.id), ["updated::newer", "updated::older", "created::a", "a::a", "a::z", "b::a", "undated::a"])
        XCTAssertEqual(entries.privateRows.first?.sessionDate, date(30))
        XCTAssertEqual(entries.privateRows[2].sessionDate, date(20))
        XCTAssertNil(entries.privateRows.last?.sessionDate)
    }

    func testSharedSortUsesInterjectionCreatedDateAcrossLayers() throws {
        let entries = try build(layers: [layer("a"), layer("b")], shared: [
            sharedNote("old", layerID: "a", created: 1), sharedNote("new", layerID: "a", created: 30),
            sharedNote("middle", layerID: "b", created: 20)
        ])
        XCTAssertEqual(entries.sharedRows.map(\.id), ["shared::a::new", "shared::b::middle", "shared::a::old"])
    }

    func testUnlinkedLayerAppearsWithIdentityTitleButDeletedLayerDoesNot() throws {
        let entries = try build(layers: [layer("unlinked", itemID: nil), layer("deleted", deleted: true)], shared: [
            sharedNote("note", layerID: "unlinked"), sharedNote("hidden", layerID: "deleted")
        ])
        XCTAssertEqual(entries.sharedRows.map(\.id), ["shared::unlinked::note"])
        XCTAssertEqual(entries.sharedRows.first?.itemTitle, "Packet title")
    }

    func testQueryMatchesTitleTextAndCollectionIgnoringCaseAndAccents() {
        let values = ["Café title", "Résumé text", "École collection"]
        for text in ["CAFE", "resume", "ECOLE", " title RESUME ", "\n  ", "", "cafe\u{301}"] {
            XCTAssertTrue(MarginCollectionQuery(text: text).matches(values), text)
        }
        for text in ["unrelated", "cafes", "title-text", String(repeating: "z", count: 2_000)] {
            XCTAssertFalse(MarginCollectionQuery(text: text).matches(values), text)
        }
        XCTAssertTrue(MarginCollectionQuery().matches([]))
        XCTAssertFalse(MarginCollectionQuery(text: "title").matches([]))
    }

    func testQueryItemScopeAndAllPublicInitializerForms() {
        let all = MarginCollectionQuery()
        for id: String? in [nil, "item", "other", ""] { XCTAssertTrue(all.includes(itemID: id)) }
        let scoped = MarginCollectionQuery(itemID: "item")
        XCTAssertTrue(scoped.includes(itemID: "item"))
        for id: String? in [nil, "other", "ITEM", ""] { XCTAssertFalse(scoped.includes(itemID: id)) }
        XCTAssertEqual(all.filter, .all)
        XCTAssertEqual(all.text, "")
        XCTAssertEqual(MarginCollectionQuery(text: "words", filter: .starred).text, "words")
        XCTAssertEqual(MarginCollectionQuery(filter: .shared, itemID: "item").filter, .shared)
        XCTAssertEqual(MarginCollectionQuery(text: "words", filter: .attention, itemID: "item").itemID, "item")
    }

    func testFilterTitlesStayByteIdentical() {
        XCTAssertEqual(MarginCollectionFilter.allCases.map(\.title), ["Mine", "Starred", "Needs attention", "Shared"])
    }

    func testSourceContextJoinsWithEllipsisAndKeepsTheTextNearestTheMarginPastTheLimit() {
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: " before ", anchorAfter: " after "), " before  …  after ")
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: "\n ", anchorAfter: "after"), "after")
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: "before", anchorAfter: nil), "before")
        XCTAssertNil(MarginCollection.sourceContext(anchorBefore: nil, anchorAfter: " \n"))
        // Exactly the limit is not cut; one more character is (#2482).
        let fits = String(repeating: "a", count: 300) + " … " + String(repeating: "b", count: 297)
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: String(repeating: "a", count: 300), anchorAfter: String(repeating: "b", count: 297)), fits)
        let character = "👩🏽‍💻"
        // Each side keeps its half, so the end of `before` and the start of `after` survive; the far ends go.
        let both = MarginCollection.sourceContext(
            anchorBefore: "far" + String(repeating: "x", count: 400) + "near", anchorAfter: "next" + String(repeating: "y", count: 400) + "far")
        XCTAssertEqual(both?.count, 600)
        XCTAssertTrue(both?.hasPrefix("xxx") == true && both?.hasSuffix("yyy") == true)
        XCTAssertTrue(both?.contains("near … next") == true, both ?? "")
        // A short side gives its unused room to the other.
        let shortBefore = MarginCollection.sourceContext(anchorBefore: "before", anchorAfter: String(repeating: "y", count: 700))
        XCTAssertEqual(shortBefore, "before … " + String(repeating: "y", count: 600 - "before … ".count))
        let shortAfter = MarginCollection.sourceContext(anchorBefore: String(repeating: "x", count: 700), anchorAfter: "after")
        XCTAssertEqual(shortAfter, String(repeating: "x", count: 600 - " … after".count) + " … after")
        // One side alone: before keeps its end, after keeps its start. Characters are never split.
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: String(repeating: character, count: 599) + "AB", anchorAfter: nil), String(repeating: character, count: 598) + "AB")
        XCTAssertEqual(MarginCollection.sourceContext(anchorBefore: nil, anchorAfter: String(repeating: "é", count: 601)), String(repeating: "é", count: 600))
    }

    func testThrowingReadsDoNotReturnPartialListsAndKeepReadOrder() throws {
        enum ReadFailure: Error { case expected }
        let previous = try build(notes: [note("previous")], layers: [layer("old")], shared: [sharedNote("previous", layerID: "old")])
        for failingRead in ["session", "layers", "layer-b"] {
            var published = previous
            var reads: [String] = []
            XCTAssertThrowsError(published = try MarginCollection.build(items: [item()], sessions: [session()], loadInterjections: { _ in
                reads.append("session")
                if failingRead == "session" { throw ReadFailure.expected }
                return [self.note("replacement")]
            }, loadImportedLayers: {
                reads.append("layers")
                if failingRead == "layers" { throw ReadFailure.expected }
                return [self.layer("a"), self.layer("b")]
            }, loadImportedInterjections: { id in
                reads.append("layer-" + id)
                if failingRead == "layer-b" && id == "b" { throw ReadFailure.expected }
                return [self.sharedNote("replacement", layerID: id)]
            })) { XCTAssertTrue($0 is ReadFailure) }
            XCTAssertEqual(published, previous)
            let expected = ["session", "layers", "layer-a", "layer-b"]
            XCTAssertEqual(reads, Array(expected.prefix(through: try XCTUnwrap(expected.firstIndex(of: failingRead)))))
        }
    }

    // These source checks pin the app/core identity and diagnostic boundary on Linux too.
    // Runtime publication and playback remain covered by the unchanged app-hosted tests.
    func testAppAndBuilderKeepPrivateAndSharedIdentityFormats() throws {
        let entries = try build(notes: [note("same")], layers: [layer("layer")], shared: [sharedNote("same", layerID: "layer")])
        XCTAssertEqual(entries.privateRows.first?.id, "session::same")
        XCTAssertEqual(entries.sharedRows.first?.id, "shared::layer::same")
        let rows = try appSource("ExperienceModels.swift")
        let model = try appSource("Gate1AppModel.swift")
        XCTAssertTrue(rows.contains(#"var id: String { "\(interjection.sessionId)::\(interjection.id)" }"#))
        XCTAssertTrue(rows.contains(#"var id: String { "shared::\(layer.id)::\(interjection.id)" }"#))
        let curation = try appSource("Gate1AppModel+MarginCuration.swift")
        XCTAssertTrue(curation.contains(#"static func marginIdentity(_ interjection: Interjection) -> String {"# + "\n" + #"        "\(interjection.sessionId)::\(interjection.id)""#))
        XCTAssertTrue(model.contains(#"let targetID = "shared::\(row.layer.id)::\(row.interjection.id)""#))
    }

    func testAppRefreshKeepsDiagnosticAndPublishesOnlyAfterSuccessfulBuildInOrder() throws {
        // The main-thread rebuild moved next to the off-main reads it is sequenced with (#2505).
        let model = try appSource("Gate1AppModel+MarginRowsRefresh.swift")
        let start = try XCTUnwrap(model.range(of: "    func refreshMarginRows() {"))
        let end = try XCTUnwrap(model.range(of: "    func refreshMarginRowsAsync() async {", range: start.upperBound..<model.endIndex))
        let refresh = String(model[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(refresh.contains(#"diagnostics["marginRefresh"] = "failed:\(String(describing: type(of: error)))""#))
        var remainder = refresh[...]
        for fragment in ["let entries = try MarginRowsReading.all(", "noteRebuild()", "publishMarginEntries(entries)", "} catch {"] {
            let range = try XCTUnwrap(remainder.range(of: fragment), fragment)
            remainder = remainder[range.upperBound...]
        }
        XCTAssertFalse(remainder.contains("publishMarginEntries"))
        XCTAssertFalse(remainder.contains("marginRows ="))
        let publishStart = try XCTUnwrap(model.range(of: "    private func publishMarginEntries("))
        let publish = model[publishStart.upperBound...].prefix { $0 != "}" }
        var published = publish[...]
        for fragment in ["sharedMarginRows = entries.sharedRows.map", "marginRows = entries.privateRows.map", "marginOutput.deliverSoon()"] {
            let range = try XCTUnwrap(published.range(of: fragment), fragment)
            published = published[range.upperBound...]
        }
    }

    private func build(notes: [Interjection] = [], layers: [ImportedCommentaryLayer] = [], shared: [ImportedCommentaryInterjection] = []) throws -> MarginCollection.Entries {
        try MarginCollection.build(items: [item()], sessions: [session()], loadInterjections: { _ in notes }, loadImportedLayers: { layers }, loadImportedInterjections: { id in shared.filter { $0.layerId == id } })
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func item(_ id: String = "item", deleted: Bool = false) -> Item {
        Item(id: id, title: "Title " + id, mediaType: "text", text: "source", externalReference: nil, status: "ready", deletedAt: deleted ? date(1) : nil)
    }

    private func session(_ id: String = "session", itemID: String = "item", created: Double? = nil, updated: Double? = nil) -> Session {
        Session(id: id, itemId: itemID, createdAt: created.map(date), updatedAt: updated.map(date), status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: itemID, position: Position(), completionPercent: 0, playbackRate: 1)
    }

    private func note(_ id: String, sessionID: String = "session", created: Double = 10, status: String = "active") -> Interjection {
        Interjection(id: id, itemId: "item", sessionId: sessionID, targetType: .item, targetId: "item", createdAt: date(created), roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "before", anchorAfter: "after"), audioPath: nil, audioStatus: "missing", transcriptionStatus: "complete", transcript: "words", cleanedTranscript: nil, displayText: nil, status: status)
    }

    private func layer(_ id: String, itemID: String? = "item", deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(id: id, itemId: itemID, packageDigest: "digest", packageId: "packet", itemIdentity: SharedItemIdentity(itemType: .text, title: "Packet title"), importedAt: date(1), deletedAt: deleted ? date(1) : nil)
    }

    private func sharedNote(_ id: String, layerID: String, created: Double = 10) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(id: id, layerId: layerID, packageScopedId: id, createdAt: date(created), anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "words")
    }

    private func appSource(_ name: String) throws -> String {
        try TestInputs.text(.appSources, name)
    }
}
