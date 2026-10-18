import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest

/// A map-only `.spokenmargins` packet for an article or a PDF (#1471): it travels, earlier builds refuse it in their
/// usual words, and its chapters land on a listener's own copy of the text even when that copy differs.
final class TextListeningMapPacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextListeningMapPacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Text

    private let paragraphs = [
        "The harbour town woke slowly that morning, with the fishing boats rocking against their ropes and the gulls arguing over scraps on the quay.",
        "Marta carried her father's ledger down to the customs shed, where a clerk with ink on his cuffs promised to read every line before noon.",
        "By midday the wind had turned, and the captains began to say that the barometer was falling faster than anyone had seen since the great storm.",
        "Nobody believed the old signalman until the lamps along the breakwater began to swing, and then the whole street went quiet at once.",
        "Evening brought the first rain, a thin grey curtain that blurred the lights of the ferry and sent the children running for the arcade.",
        "In the morning the water had gone back, leaving only seaweed on the steps and a strange calm that nobody in the town quite trusted."
    ]
    private var text: String { paragraphs.joined(separator: "\n\n") }

    private func scenes(of text: String? = nil, summaries: [String]? = nil) -> [ListeningMapPacketBuilder.Scene] {
        let blocks = ListeningEdition.blocks(in: text ?? self.text)
        let words = summaries ?? [
            "A quiet start in the harbour.", "Marta takes the ledger to the customs shed.", "The weather turns against the captains.",
            "A warning nobody heeds.", "Rain arrives with the evening ferry.", "A suspicious calm follows the storm."
        ]
        return blocks.enumerated().map { index, block in
            .init(title: "Part \(index + 1)", summary: words[index], startChar: block.startChar, endChar: block.endChar)
        }
    }

    private func article(url: String? = "https://example.com/harbour") -> SharedItemIdentity {
        ListeningMapPacketBuilder.identity(itemType: .text, title: "The Harbour Town", canonicalURL: url, text: text)
    }

    private func proposal(of text: String? = nil, scenes: [ListeningMapPacketBuilder.Scene]? = nil) throws -> PortableListeningMapProposalArtifact {
        let source = text ?? self.text
        return try ListeningMapPacketBuilder.proposal(
            id: "map-harbour", generator: "test", languageCode: "en", createdAt: created,
            scenes: scenes ?? self.scenes(of: source), text: source
        )
    }

    private func packet(_ item: SharedItemIdentity? = nil) throws -> PreparedSpokenMarginsPackage {
        try ListeningMapPacketBuilder.prepare(
            packageId: "map-packet-harbour", createdAt: created, item: item ?? article(),
            proposal: try proposal(), senderDisplayLabel: "A Friend"
        )
    }

    private func write(_ prepared: PreparedSpokenMarginsPackage, name: String = "map") throws -> URL {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportMapOnlyPacket(prepared, to: url)
        return url
    }

    private func read(_ url: URL) throws -> VerifiedSpokenMarginsPackage {
        try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets-\(UUID().uuidString)"))
    }

    // MARK: The packet

    func testAMapPacketCarriesTheMapAndNoMargins() throws {
        let verified = try read(try write(try packet()))
        XCTAssertTrue(ListeningMapPacket.isMapPacket(verified.manifest))
        XCTAssertEqual(verified.manifest.requiredCapabilities, [SharedCommentaryLayerArtifact.schemaVersion, ListeningMapPacket.capability])
        XCTAssertEqual(verified.commentaryLayers.map(\.interjections.count), [0], "the empty layer is what lets earlier builds reach their capability check")
        let map = try XCTUnwrap(ListeningMapPacket.proposal(in: verified))
        XCTAssertEqual(map.scenes.map(\.title), (1...6).map { "Part \($0)" })
        XCTAssertEqual(map.scenes.map(\.summaryText), scenes().map(\.summary))
        XCTAssertEqual(verified.manifest.itemTransport.kind, .reference)
        XCTAssertTrue(verified.manifest.redactions.fullItemOmitted)
    }

    func testThePacketHoldsOnlyAFewWordsOfTheTextPerScene() throws {
        let map = try proposal()
        for scene in map.scenes {
            for anchor in [scene.startAnchor, scene.endAnchor] {
                let quoted = [anchor.prefix, anchor.exactText, anchor.suffix].compactMap { $0 }.joined(separator: " ")
                let words = quoted.split(whereSeparator: \.isWhitespace).count
                XCTAssertLessThan(words, PortableListeningMapContract.verbatimRunWords, "\(scene.id) quotes \(words) words")
            }
        }
        let data = try JSONEncoder().encode(map)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(paragraphs[1]), "no whole paragraph travels")
    }

    func testAPacketWithoutALinkAsksTheListenerForTheItem() throws {
        let verified = try read(try write(try packet(article(url: nil))))
        XCTAssertEqual(verified.manifest.itemTransport.kind, .recipientSupplied)
        XCTAssertNil(verified.manifest.item.canonicalURL)
    }

    func testAPrivateLinkNeverTravelsInTheItemIdentity() {
        let identity = ListeningMapPacketBuilder.identity(
            itemType: .text, title: "T", canonicalURL: "https://www.patreon.com/posts/123?token=abc", text: text)
        XCTAssertNil(identity.canonicalURL)
        XCTAssertNil(identity.originalURL)
    }

    func testThePreviewNamesTheChaptersAndTheMissingMargins() throws {
        let verified = try read(try write(try packet()))
        let preview = SpokenMarginsPackageArchive.previewMarkdown(
            verified.manifest, commentaryLayers: verified.commentaryLayers, listeningMapProposals: verified.listeningMapProposals)
        XCTAssertTrue(preview.contains("Listening Map of 6 chapters"))
        XCTAssertTrue(preview.contains("Chapter 3: Part 3"))
        XCTAssertFalse(preview.contains("0 reviewed Margins"))
    }

    func testTheImporterRefusesAMapPacketInsteadOfMakingAnEmptyLayer() throws {
        let verified = try read(try write(try packet()))
        XCTAssertThrowsError(try SpokenMarginsPackageImporter.importPackage(verified, repository: InMemorySessionRepository()))
    }

    func testTheReaderRefusesAMapPacketThatCarriesTwoMaps() throws {
        let one = try packet()
        var manifest = one.manifest
        var data = one.artifactData
        let second = "artifacts/listening-map-proposal-0002.json"
        let firstJSON = String(decoding: try XCTUnwrap(data["artifacts/listening-map-proposal-0001.json"]), as: UTF8.self)
        data[second] = Data(firstJSON.replacingOccurrences(of: "map-harbour", with: "map-second").utf8)
        manifest.artifacts.append(SpokenMarginsArtifactDescriptor(
            id: "map-second", kind: SpokenMarginsArtifactKind.listeningMapProposal,
            schemaVersion: PortableListeningMapProposalArtifact.schemaVersion, path: second, required: true))
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(
            PreparedSpokenMarginsPackage(manifest: manifest, artifactData: data, assetFiles: [:]),
            to: root.appendingPathComponent("two.spokenmargins"))) {
            guard case .invalidManifest(let reason) = $0 as? SpokenMarginsPackageArchiveError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("listening map packet"), reason)
        }
    }

    func testTheReaderRefusesAMapPacketThatCarriesTheText() throws {
        let one = try packet()
        var manifest = one.manifest
        var data = one.artifactData
        let embedded = EmbeddedTextItemArtifact(originalMediaType: "text", text: text)
        data["artifacts/embedded-item.json"] = try JSONEncoder().encode(embedded)
        manifest.artifacts.append(SpokenMarginsArtifactDescriptor(
            id: embedded.id, kind: SpokenMarginsArtifactKind.embeddedTextItem,
            schemaVersion: embedded.schemaVersion, path: "artifacts/embedded-item.json", required: true))
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(
            PreparedSpokenMarginsPackage(manifest: manifest, artifactData: data, assetFiles: [:]),
            to: root.appendingPathComponent("with-text.spokenmargins")))
    }

    func testTheBuilderRefusesAPodcast() throws {
        let podcast = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/ep", title: "Episode")
        XCTAssertThrowsError(try ListeningMapPacketBuilder.prepare(
            packageId: "p", createdAt: created, item: podcast, proposal: try proposal(), senderDisplayLabel: nil)) {
            XCTAssertEqual($0 as? ListeningMapPacketBuilder.BuildError, .itemNotShareable)
        }
    }

    // MARK: The builder checks the map before it leaves

    func testASummaryThatCopiesTheTextIsRefused() throws {
        var copied = scenes()
        copied[1].summary = "Marta carried her father's ledger down to the customs shed, where a clerk with ink on his cuffs"
        XCTAssertThrowsError(try proposal(scenes: copied)) {
            guard case .contractViolation = $0 as? ListeningMapPacketBuilder.BuildError else { return XCTFail("\($0)") }
        }
    }

    func testAScenePastTheEndOfTheTextIsRefused() throws {
        var bad = scenes()
        bad[5].endChar = text.count + 40
        XCTAssertThrowsError(try proposal(scenes: bad)) {
            XCTAssertEqual($0 as? ListeningMapPacketBuilder.BuildError, .sceneOutsideText("Part 6"))
        }
    }

    func testScenesThatRunBackwardsAreRefused() throws {
        var bad = scenes()
        bad.swapAt(2, 3)
        XCTAssertThrowsError(try proposal(scenes: bad)) {
            XCTAssertEqual($0 as? ListeningMapPacketBuilder.BuildError, .scenesOutOfOrder("Part 3"))
        }
    }

    func testASceneWhoseFirstWordsRepeatCannotBePlacedAndIsRefused() throws {
        let line = "We went back to the old mill by the river and found the door open again."
        let repeated = [line + " Alpha one.", "Between them sat a dull paragraph about nothing in particular at all.", line + " Alpha one."]
        let source = repeated.joined(separator: "\n\n")
        let blocks = ListeningEdition.blocks(in: source)
        let scenes = blocks.enumerated().map {
            ListeningMapPacketBuilder.Scene(title: "S\($0.offset + 1)", summary: "Summary \($0.offset + 1).", startChar: $0.element.startChar, endChar: $0.element.endChar)
        }
        XCTAssertThrowsError(try ListeningMapPacketBuilder.proposal(
            id: "m", generator: "t", languageCode: nil, createdAt: created, scenes: scenes, text: source)) {
            XCTAssertEqual($0 as? ListeningMapPacketBuilder.BuildError, .sceneCannotBePlaced("S1"))
        }
    }

    // MARK: Placement on the listener's copy

    private func place(on copy: String, hash: String? = nil) throws -> TextListeningMapPlacement {
        TextListeningMapPlacer.place(try proposal(), in: copy, expectedExactEditionSHA256: hash)
    }

    func testTheSameTextPlacesEveryChapterWhereTheSenderHadIt() throws {
        let placement = try place(on: text, hash: PortableArticleAnchorResolver.exactEditionSHA256(text))
        XCTAssertTrue(placement.isComplete)
        XCTAssertEqual(placement.scenes.map(\.startChar), scenes().map(\.startChar))
        XCTAssertEqual(placement.scenes.last?.endChar, text.count)
        XCTAssertNil(placement.shortfallDescription)
        XCTAssertEqual(placement.chapters.map(\.title), (1...6).map { "Part \($0)" })
        XCTAssertEqual(placement.summariesByChapterId["scene-2"], "Marta takes the ledger to the customs shed.")
    }

    func testDifferentWhitespaceStillPlacesEveryChapter() throws {
        let copy = paragraphs.joined(separator: "\r\n\r\n\n").replacingOccurrences(of: " the ", with: "  the\t")
        let placement = try place(on: copy)
        XCTAssertTrue(placement.isComplete, "unplaced: \(placement.unplacedSceneIds)")
        XCTAssertEqual(placement.scenes.map(\.startChar), placement.scenes.map(\.startChar).sorted())
    }

    func testCurlyQuotesAndDashesStillPlaceEveryChapter() throws {
        let copy = text.replacingOccurrences(of: "father's", with: "father’s").replacingOccurrences(of: ", with", with: " — with")
        let placement = try place(on: copy)
        XCTAssertTrue(placement.isComplete, "unplaced: \(placement.unplacedSceneIds)")
    }

    func testAChangedParagraphLeavesOneChapterOutAndSaysSo() throws {
        var edited = paragraphs
        edited[3] = "A completely rewritten paragraph that says something else about the signalman and his lamps along the water."
        let placement = try place(on: edited.joined(separator: "\n\n"))
        XCTAssertEqual(placement.unplacedSceneIds, ["scene-4"])
        XCTAssertEqual(placement.scenes.map(\.id), ["scene-1", "scene-2", "scene-3", "scene-5", "scene-6"])
        XCTAssertTrue(placement.isUsable)
        XCTAssertFalse(placement.isComplete)
        XCTAssertEqual(placement.shortfallDescription, "Placed 5 of 6 chapters. The rest weren't found in your copy.")
        // The chapter before a missing one runs up to the next chapter that was found.
        XCTAssertEqual(placement.scenes[2].endChar, placement.scenes[3].startChar)
    }

    func testAnEditionWithAnExtraIntroductionMovesEveryChapterDown() throws {
        let intro = "Subscribe to our newsletter for more stories from the coast.\n\n"
        let placement = try place(on: intro + text)
        XCTAssertTrue(placement.isComplete)
        XCTAssertEqual(placement.scenes.map(\.startChar), scenes().map { $0.startChar + intro.count })
    }

    func testAnEditionWithAMovedSectionKeepsTheLongestRunInReadingOrder() throws {
        var moved = paragraphs
        moved.append(moved.remove(at: 1))
        let placement = try place(on: moved.joined(separator: "\n\n"))
        XCTAssertEqual(placement.scenes.count, 5, "the chapter that jumped to the end is left out, the rest keep their order")
        XCTAssertEqual(placement.scenes.map(\.startChar), placement.scenes.map(\.startChar).sorted())
        XCTAssertTrue(placement.isUsable)
    }

    func testATextWithAnotherStoryPlacesNothing() throws {
        let placement = try place(on: "Completely unrelated words about gardens, sheds and a long afternoon of tea.\n\nMore of the same.")
        XCTAssertTrue(placement.scenes.isEmpty)
        XCTAssertFalse(placement.isUsable)
        XCTAssertEqual(placement.unplacedSceneIds.count, 6)
    }

    func testAMapThatPlacesFewerThanHalfOfItsChaptersIsNotUsable() throws {
        let copy = paragraphs.prefix(2).joined(separator: "\n\n") + "\n\nSomething else entirely about winter tides and a lighthouse keeper's cat.\n\nAnd another unrelated page."
        let placement = try place(on: copy)
        XCTAssertEqual(placement.scenes.count, 2)
        XCTAssertFalse(placement.isUsable)
    }

    func testTheSenderOffsetsAreNotTrustedOnAnotherEdition() throws {
        // The hash says "same edition" but the text is shifted: the offsets would point at the wrong words, so
        // placement falls back to the quotations.
        let intro = "Extra opening line.\n\n"
        let placement = try place(on: intro + text, hash: PortableArticleAnchorResolver.exactEditionSHA256(text))
        XCTAssertEqual(placement.scenes.map(\.startChar), scenes().map { $0.startChar + intro.count })
    }

    func testPlacementOfTwoHundredChaptersOnALongTextIsQuick() throws {
        let blocks = (0..<200).map { "Chapter marker number \($0) opens here with distinctive words about subject \($0 * 7), followed by a long run of ordinary filler text that goes on for a while so the paragraph is not tiny." }
        let source = blocks.joined(separator: "\n\n")
        let map = try ListeningMapPacketBuilder.proposal(
            id: "big", generator: "t", languageCode: nil, createdAt: created,
            scenes: ListeningEdition.blocks(in: source).enumerated().map {
                .init(title: "C\($0.offset)", summary: "Summary \($0.offset).", startChar: $0.element.startChar, endChar: $0.element.endChar)
            }, text: source)
        let started = Date()
        let placement = TextListeningMapPlacer.place(map, in: source)
        XCTAssertEqual(placement.scenes.count, 200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    // MARK: Finding the item

    private func textItem(id: String, title: String, body: String, reference: String?) -> Item {
        Item(id: id, title: title, mediaType: "text", text: body, externalReference: reference, status: "ready", externalReferenceType: reference == nil ? "manual" : "url")
    }

    func testAMapMatchesTheArticleTheListenerHasByLink() throws {
        let items = [textItem(id: "other", title: "Other", body: "x y z", reference: "https://example.com/other"),
                     textItem(id: "mine", title: "Same article", body: text, reference: "https://example.com/harbour/")]
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: article(), proposal: try proposal(), among: items), .item("mine"))
    }

    func testAMapMatchesAnArticleWithTheSameTextAtAnotherLink() throws {
        let items = [textItem(id: "mine", title: "The Harbour Town", body: text, reference: "https://mirror.example.org/a")]
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: article(), proposal: try proposal(), among: items), .item("mine"))
    }

    func testAnArticleNotInTheLibraryHasNoMatch() throws {
        let items = [textItem(id: "other", title: "Other", body: "Something else.", reference: "https://example.com/other")]
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: article(), proposal: try proposal(), among: items), .none)
    }

    func testAPickedPDFWithDifferentExtractedTextMatchesByWhereTheChaptersLand() throws {
        let extracted = paragraphs.joined(separator: "\n") .replacingOccurrences(of: "harbour", with: "harbor")
        let pdfIdentity = ListeningMapPacketBuilder.identity(itemType: .pdf, title: "The Harbour Town", canonicalURL: nil, text: text)
        let items = [
            textItem(id: "pdf", title: "harbour-town.pdf", body: extracted, reference: "harbour-town.pdf"),
            textItem(id: "other-pdf", title: "other.pdf", body: "Unrelated words about gardens.", reference: "other.pdf"),
            textItem(id: "article", title: "An article", body: extracted, reference: "https://example.com/harbour-copy")
        ]
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: pdfIdentity, proposal: try proposal(), among: items), .item("pdf"))
    }

    func testTwoPDFsThatHoldTheMapEquallyAreAmbiguous() throws {
        let extracted = paragraphs.joined(separator: "\n").replacingOccurrences(of: "harbour", with: "harbor")
        let pdfIdentity = ListeningMapPacketBuilder.identity(itemType: .pdf, title: "The Harbour Town", canonicalURL: nil, text: text)
        let items = [textItem(id: "a", title: "a.pdf", body: extracted, reference: "a.pdf"),
                     textItem(id: "b", title: "b.pdf", body: extracted, reference: "b.pdf")]
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: pdfIdentity, proposal: try proposal(), among: items), .ambiguous)
    }

    func testADeletedItemIsNeverMatched() throws {
        var gone = textItem(id: "gone", title: "The Harbour Town", body: text, reference: "https://example.com/harbour")
        gone.deletedAt = Date()
        XCTAssertEqual(ListeningMapPacketItemMatcher.match(packetItem: article(), proposal: try proposal(), among: [gone]), .none)
    }
}
