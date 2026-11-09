import Foundation
import SessionKit
import SessionKitPersistence
import XCTest

/// A friend who shares again sends the Margins they already sent (#858). Each row is a neighbouring
/// input of the matching rule, run through a real SQLite Library. The same flow with real packets
/// is in CoopResendTests, in Packages/SessionKitTools (#1873).
final class ImportedMarginResendsTests: XCTestCase {
    private var folder: URL!
    private var store: SQLiteSessionStore!
    private let item = SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/episodes/harbour-lights", title: "Harbour Lights")
    private var captureOrigins: [String: String] = [:]
    private var clock = Date(timeIntervalSince1970: 1_777_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("resends-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The rows

    func testTheSamePacketTwiceIsOneLayer() throws {
        let first = packet("O", from: "Ada", [("hello", 60_000), ("again", 120_000)])
        XCTAssertTrue(try send(first).isImported)
        XCTAssertFalse(try send(first).isImported)
        XCTAssertEqual(try visible(), ["Ada|60000|hello", "Ada|120000|again"].sorted())
    }

    func testTheUpdateAfterTheOriginalAddsOnlyTheNewMargin() throws {
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])
        XCTAssertTrue(try send(original).isImported)
        guard case .imported(_, let ids) = try send(update) else { return XCTFail("the update brings a new Margin") }
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        // The update's names for the Margins already held are kept on them.
        XCTAssertEqual(try identities(of: "one"), [id("O", "O-1"), id("U", "U-1")].sorted(by: Self.order))
    }

    func testTheUpdateBeforeTheOriginalLeavesTheOriginalOut() throws {
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])
        XCTAssertTrue(try send(update).isImported)
        XCTAssertFalse(try send(original).isImported, "everything in it is already held")
        XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        XCTAssertEqual(try identities(of: "one"), [id("O", "O-1"), id("U", "U-1")].sorted(by: Self.order))
        // Opening the original again changes nothing.
        XCTAssertFalse(try send(original).isImported)
        XCTAssertEqual(try identities(of: "one").count, 2)
    }

    func testEveryOrderOfThreeShareGivesTheSameMargins() throws {
        let packets = [
            packet("O", from: "Ada", [("one", 60_000)]),
            packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]),
            packet("V", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)]),
        ]
        var outcomes: Set<[String]> = []
        var names: Set<[String]> = []
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            try setUpWithError()
            for index in order { _ = try send(packets[index]) }
            outcomes.insert(try visible())
            names.insert(try ["one", "two", "three"].map { try identities(of: $0).map { "\($0.packageDigest)/\($0.packageScopedId)" }.joined(separator: ",") })
            XCTAssertEqual(try visible().count, 3, "order \(order)")
        }
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(names.count, 1, "each Margin is known by every packet name in any order")
    }

    func testAMarginTheFriendDeletedBetweenSharesStaysHeld() throws {
        // The update no longer has "one"; the listener may have heard it or replied to it.
        let original = packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)])
        let update = packet("U", from: "Ada", [("two", 120_000), ("three", 180_000)])
        for order in [[original, update], [update, original]] {
            try setUpWithError()
            for packet in order { _ = try send(packet) }
            XCTAssertEqual(try visible(), ["Ada|60000|one", "Ada|120000|two", "Ada|180000|three"].sorted())
        }
    }

    func testEditedWordsAreAnotherMargin() throws {
        // Without a stable id in the packet an edit can't be told from a new Margin at the same place.
        _ = try send(packet("O", from: "Ada", [("teh point", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("the point", 60_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|teh point", "Ada|60000|the point"].sorted())
    }

    func testTheSameWordsAtAnotherPlaceAreAnotherMargin() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000), ("love this", 600_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|love this", "Ada|600000|love this"].sorted())
    }

    func testTheSameWordsAtTheSamePlaceFromAnotherPersonAreNotMerged() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ben", [("love this", 60_000)]))
        XCTAssertEqual(try visible(), ["Ada|60000|love this", "Ben|60000|love this"].sorted())
    }

    func testTwoPeopleWithOneLabelNeedTheSameWordsPlaceAndVoice() throws {
        _ = try send(packet("O", from: "Sam", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Sam", [("love this", 61_000), ("love this!", 60_000)]))
        XCTAssertEqual(try visible().count, 3)
    }

    func testAVoiceMarginAndATextMarginAreNotTheSame() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], voiceMs: 4_000))
        XCTAssertEqual(try visible().count, 2)
        _ = try send(packet("V", from: "Ada", [("love this", 60_000)], voiceMs: 4_000))
        XCTAssertEqual(try visible().count, 2, "the same voice Margin again is the one already held")
    }

    func testAcousticEvidenceIdsDoNotMakeAMarginNew() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], evidence: ["signature-a"]))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], evidence: ["signature-b"]))
        XCTAssertEqual(try visible().count, 1)
    }

    func testSpacesAroundTheWordsDoNotMakeAMarginNew() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("  love this\n", 60_000)]))
        XCTAssertEqual(try visible().count, 1)
    }

    func testTheSameMarginsOnAnotherItemAreKept() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], itemId: "item-1"))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], itemId: "item-2"))
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "item-1").count, 1)
        XCTAssertEqual(try store.loadImportedCommentaryLayers(itemId: "item-2").count, 1)
    }

    func testASenderWithNoLabelIsNeverMerged() throws {
        _ = try send(packet("O", from: nil, [("love this", 60_000)]))
        _ = try send(packet("U", from: nil, [("love this", 60_000)]))
        XCTAssertEqual(try visible().count, 2)
    }

    func testAPacketWithoutAnItemYetIsImportedWhole() throws {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], itemId: nil))
        XCTAssertTrue(try send(packet("U", from: "Ada", [("love this", 60_000)], itemId: nil)).isImported)
    }

    func testTwoIdenticalMarginsInOnePacketKeepBothAndAreNotCountedAgain() throws {
        // Said twice at the same place: both stay. The update that carries both adds neither.
        _ = try send(packet("O", from: "Ada", [("mm", 60_000), ("mm", 60_000)]))
        XCTAssertFalse(try send(packet("U", from: "Ada", [("mm", 60_000), ("mm", 60_000)])).isImported)
        XCTAssertEqual(try visible().count, 2)
        // A third one is new.
        XCTAssertTrue(try send(packet("V", from: "Ada", [("mm", 60_000), ("mm", 60_000), ("mm", 60_000)])).isImported)
        XCTAssertEqual(try visible().count, 3)
    }

    func testALayerTheListenerDeletedIsBroughtBackByTheUpdate() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "item-1").first)
        layer.deletedAt = clock
        try store.saveImportedCommentaryLayer(layer)
        _ = try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        let live = try store.loadImportedCommentaryLayers(itemId: "item-1").filter { $0.deletedAt == nil }
        XCTAssertEqual(try live.flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }.count, 2)
    }

    func testALayerForTheWrongSourceDoesNotAbsorbTheUpdate() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var layer = try XCTUnwrap(store.loadImportedCommentaryLayers(itemId: "item-1").first)
        layer.sourceResolutionStatus = .wrongSource
        try store.saveImportedCommentaryLayer(layer)
        XCTAssertTrue(try send(packet("U", from: "Ada", [("one", 60_000)])).isImported)
    }

    func testAMarginTheListenerHeardIsNotNewAgain() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        let held = try XCTUnwrap(try margins().first)
        let heardAt = clock
        _ = try store.markImportedCommentaryInterjectionHeard(id: held.id, at: heardAt)
        _ = try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        let all = try margins()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.approvedTranscript == "one" }?.firstHeardAt, heardAt)
        XCTAssertNil(all.first { $0.approvedTranscript == "two" }?.firstHeardAt)
    }

    // MARK: Replies

    func testARepliesParentIsFoundByEitherPacketsName() throws {
        let replyToOriginal = reply("R1", parent: id("O", "O-1"))
        let replyToUpdate = reply("R2", parent: id("U", "U-2"))
        for order in [["O", "U"], ["U", "O"]] {
            try setUpWithError()
            let packets = ["O": packet("O", from: "Ada", [("one", 60_000), ("two", 120_000)]),
                           "U": packet("U", from: "Ada", [("one", 60_000), ("two", 120_000), ("three", 180_000)])]
            for name in order { _ = try send(packets[name]!) }
            _ = try send(replyToOriginal)
            _ = try send(replyToUpdate)
            let graph = try graph()
            let parentOfOne = try XCTUnwrap(margins().first { $0.approvedTranscript == "one" })
            let parentOfTwo = try XCTUnwrap(margins().first { $0.approvedTranscript == "two" })
            for (text, parent) in [("reply to O-1", parentOfOne), ("reply to U-2", parentOfTwo)] {
                let reply = try XCTUnwrap(margins().first { $0.approvedTranscript == text })
                guard case .linked(let link)? = graph.states[.imported(reply.id)] else { return XCTFail("\(text) lost its parent in order \(order)") }
                XCTAssertEqual(link.parent, .imported(parent.id), "\(text) in order \(order)")
            }
        }
    }

    func testAReplySharedAgainKeepsOneCopyAndOneThread() throws {
        let original = packet("O", from: "Ada", [("one", 60_000)])
        let ben1 = reply("B1", parent: id("O", "O-1"), from: "Ben")
        _ = try send(original)
        _ = try send(ben1)
        // Ben shares again; his reply is in the update too.
        let ben2 = packet("B2", from: "Ben", [("reply to O-1", 60_000), ("and another", 90_000)], links: [MarginReplyLink.replying(to: id("O", "O-1"), parentConversationId: nil)])
        _ = try send(ben2)
        let bens = try margins().filter { $0.approvedTranscript.hasPrefix("reply") }
        XCTAssertEqual(bens.count, 1)
        // Ben's first reply is known by both packets (2 edges); the new one by one.
        XCTAssertEqual(try graph().threads.values.map(\.count), [3])
    }

    // MARK: Storage

    func testAMarginThatArrivedOnceHasNoPacketAliases() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(try XCTUnwrap(margins().first)), as: UTF8.self)
        XCTAssertFalse(json.contains("alsoSharedAs"), json)
    }

    func testARecordFromBeforeThisChangeStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let margin = ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "s", createdAt: clock,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1), approvedTranscript: "words"
        )
        let decoded = try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: try encoder.encode(margin))
        XCTAssertNil(decoded.alsoSharedAs)
        XCTAssertNil(decoded.shareProvenance)
        var marked = margin
        marked.alsoSharedAs = [id("U", "U-1")]
        XCTAssertEqual(try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: try encoder.encode(marked)), marked)
    }

    // Audit regressions: these run through the existing importer and real SQLite.
    func testAuditAmbiguousSameLabelKeepsIdenticalMargins() throws {
        _ = try send(packet("O", from: "Sam", [("Agreed", 60_000)]))
        _ = try send(packet("U", from: "Sam", [("Agreed", 60_000)], person: "other Sam"))
        XCTAssertEqual(try visible().count, 2)
    }

    func testAuditAmbiguousSenderNeighboursKeepBoth() throws {
        let labels: [(String?, String?)] = [
            ("Sam", "Sam"), ("Sam", "sam"), ("Sam", "  Sam\n"),
            ("José", "Jose\u{301}"), ("Sam", "Sam!"), (nil, nil), ("", " \n"),
            (String(repeating: "S", count: 120), String(repeating: "S", count: 120)),
            ("Sam", "Sаm") // Cyrillic a is a lookalike, not Latin a.
        ]
        for (first, second) in labels {
            try setUpWithError()
            _ = try send(packet("O", from: first, [("Agreed", 60_000)], provenance: false))
            _ = try send(packet("U", from: second, [("Agreed", 60_000)], provenance: false))
            XCTAssertEqual(try margins().count, 2, "\(String(describing: first)) / \(String(describing: second))")
        }
    }

    func testAuditDifferentReplyRelationshipsKeepBothInEveryOrder() throws {
        let a = MarginReplyLink.replying(to: id("Ada", "a"), parentConversationId: nil)
        let c = MarginReplyLink.replying(to: id("Chris", "c"), parentConversationId: nil)
        let alternatives: [[MarginReplyLink]] = [[], [c], [a, c], [
            MarginReplyLink(conversationId: "another-thread", parentPackageDigest: "Ada", parentPackageScopedId: "a")
        ]]
        for links in alternatives {
            let packets = [packet("O", from: "Ben", [("Agreed", 60_000)], links: [a]),
                           packet("U", from: "Ben", [("Agreed", 60_000)], links: links)]
            for order in [packets, packets.reversed()] {
                try setUpWithError()
                for packet in order { _ = try send(packet) }
                XCTAssertEqual(try margins().count, 2, "links \(links)")
                XCTAssertEqual(Set(try margins().flatMap { $0.replyLinks ?? [] }), Set([a] + links))
            }
        }
    }

    func testAuditStaleResolutionCannotEraseAliases() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var stale = try XCTUnwrap(margins().first)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)]))
        stale.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
        // A stale pass may itself have a different alias; both must survive.
        stale.alsoSharedAs = [id("V", "V-1")]
        try store.saveImportedCommentaryInterjection(stale)
        XCTAssertEqual(Set(try XCTUnwrap(margins().first).alsoSharedAs ?? []), Set([id("U", "U-1"), id("V", "V-1")]))
        stale.alsoSharedAs = nil
        try store.saveImportedCommentaryInterjection(stale)
        XCTAssertEqual(try XCTUnwrap(margins().first).alsoSharedAs?.count, 2)
    }

    func testAuditAllDeduplicatedMarginsStillSaveLayerArtifacts() throws {
        let proposal = PortableListeningMapProposalArtifact(id: "map", createdAt: clock, generator: "test", scenes: [
            PortableListeningMapScene(
                id: "scene", order: 0, summaryText: "The speaker introduces the question.",
                summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 0),
                endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 120_000)
            )
        ])
        XCTAssertTrue(PortableListeningMapContract.violations(in: proposal, itemText: nil).isEmpty)
        let spine = EditionFingerprintSpineArtifact(id: "spine", itemId: "item-1", createdAt: clock, landmarks: [])
        let sketch = TranscriptPhraseSketchArtifact(id: "sketch", itemId: "item-1", saltBase64: "salt", createdAt: clock, windows: [])
        for reverse in [false, true] {
            try setUpWithError()
            let original = packet("O", from: "Ada", [("one", 60_000)])
            let update = packet("U", from: "Ada", [("one", 60_000)])
            let layer = ImportedCommentaryLayer(
                id: "layer-U", itemId: "item-1", packageDigest: "U", packageId: "package-U",
                itemIdentity: item, displayLabel: "Ada", importedAt: clock, isEnabled: true,
                listeningMapProposals: [proposal], editionFingerprintSpines: [spine],
                transcriptPhraseSketches: [sketch], episodeMapEvidencePaths: ["signature": "/local/signature"]
            )
            if !reverse { _ = try send(original) }
            _ = try ImportedMarginResends.importLayer(layer, interjections: update.margins, repository: store)
            if reverse { _ = try send(original) }
            let saved = try XCTUnwrap(store.loadImportedCommentaryLayer(packageDigest: "U"))
            XCTAssertTrue(ImportedMarginResends.hasLayerArtifacts(saved), "the app must schedule artifact-only layers")
            if !reverse { XCTAssertTrue(try store.loadImportedCommentaryInterjections(layerId: saved.id).isEmpty) }
            XCTAssertEqual(saved.listeningMapProposals, [proposal])
            XCTAssertEqual(saved.editionFingerprintSpines, [spine])
            XCTAssertEqual(saved.transcriptPhraseSketches, [sketch])
            XCTAssertEqual(saved.episodeMapEvidencePaths, ["signature": "/local/signature"])
            XCTAssertEqual(try margins().count, 1)
        }
    }

    func testAuditProvenanceBearingSenderNeighbours() throws {
        let labels: [(String?, String?, Int)] = [
            ("Sam", "Sam", 1), ("Sam", "sam", 2), ("Sam", "  Sam\n", 1),
            ("José", "Jose\u{301}", 1), ("Sam", "Sam!", 2), (nil, nil, 2), ("", " \n", 2),
            (String(repeating: "S", count: 120), String(repeating: "S", count: 120), 1),
            ("Sam", "Sаm", 2)
        ]
        for (first, second, count) in labels {
            try setUpWithError()
            _ = try send(packet("O", from: first, [("Agreed", 60_000)], person: "one person"))
            _ = try send(packet("U", from: second, [("Agreed", 60_000)], person: "one person"))
            XCTAssertEqual(try margins().count, count, "\(String(describing: first)) / \(String(describing: second))")
        }
    }

    func testAuditProvenanceBearingWordNeighbours() throws {
        let words: [(String, String, Int)] = [
            ("Agreed", "agreed", 2), ("Agreed", " \nAgreed\t", 1), ("Café", "Cafe\u{301}", 1),
            ("Agreed", "Agreed!", 2), ("", " \n", 1),
            (String(repeating: "x", count: 50_000), String(repeating: "x", count: 50_000), 1),
            ("Agreed", "Аgreed", 2)
        ]
        for (first, second, count) in words {
            try setUpWithError()
            _ = try send(packet("O", from: "Ada", [(first, 60_000)]))
            _ = try send(packet("U", from: "Ada", [(second, 60_000)]))
            XCTAssertEqual(try margins().count, count)
        }
    }

    func testAuditReplyLinkOrderIsIrrelevant() throws {
        let a = MarginReplyLink.replying(to: id("Ada", "a"), parentConversationId: nil)
        let c = MarginReplyLink.replying(to: id("Chris", "c"), parentConversationId: nil)
        _ = try send(packet("O", from: "Ben", [("Agreed", 60_000)], links: [a, c]))
        _ = try send(packet("U", from: "Ben", [("Agreed", 60_000)], links: [c, a]))
        XCTAssertEqual(try margins().count, 1)
        XCTAssertEqual(try identities(of: "Agreed").count, 2)
    }

    func testAuditLegacyAndDistinctRecordingsNeverMerge() throws {
        for legacy in [false, true] {
            try setUpWithError()
            _ = try send(packet("O", from: "Sam", [("Agreed", 60_000)], voiceMs: 4_000, provenance: !legacy))
            _ = try send(packet("U", from: "Sam", [("Agreed", 60_000)], voiceMs: 4_000, provenance: !legacy, person: "another Sam"))
            XCTAssertEqual(try margins().count, 2)
        }
    }

    // MARK: Read aloud on a re-sent Margin (#3452)

    func testASenderWhoFlipsReadAloudOffChangesTheHeldMargin() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        XCTAssertNil(try XCTUnwrap(margins().first).senderReadAloud)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: false))
        let held = try margins()
        XCTAssertEqual(held.count, 1, "A flip must not make a second copy")
        XCTAssertEqual(held.first?.senderReadAloud, false)
        XCTAssertEqual(held.first?.readsAloud, false)
        XCTAssertEqual(held.first?.alsoSharedAs, [id("U", "U-1")], "The alias is added in the same pass")
    }

    /// The sender's app sends no key for "read aloud" and starts every draft at the default, so a re-share that only
    /// repeats an earlier Margin must not cancel the earlier "don't read aloud" (audit on 084da4b).
    func testAResendWithNoChoiceKeepsTheEarlierDontReadAloud() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], readAloud: false))
        _ = try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        let held = try margins().first { $0.approvedTranscript == "one" }
        XCTAssertEqual(held?.senderReadAloud, false)
        XCTAssertEqual(held?.readsAloud, false)
        XCTAssertNil(held?.senderReadAloudAt, "Nothing changed, so nothing is stamped")
        XCTAssertEqual(held?.alsoSharedAs, [id("U", "U-1")], "The alias still arrives")
        XCTAssertEqual(try margins().count, 2)
        // An explicit false again, then no choice again: it stays off.
        _ = try send(packet("V", from: "Ada", [("one", 60_000)], readAloud: false))
        _ = try send(packet("W", from: "Ada", [("one", 60_000)]))
        XCTAssertEqual(try margins().first { $0.approvedTranscript == "one" }?.readsAloud, false)
    }

    /// #3472: the sender's app now writes an explicit "on" when the Margin's last share said "off", so the held copy
    /// can follow the sender back.
    func testASenderWhoTurnsReadAloudBackOnChangesTheHeldMarginBack() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], readAloud: false))
        XCTAssertEqual(try XCTUnwrap(margins().first).readsAloud, false)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: true))
        let held = try margins()
        XCTAssertEqual(held.count, 1, "A flip must not make a second copy")
        XCTAssertEqual(held.first?.senderReadAloud, true)
        XCTAssertEqual(held.first?.readsAloud, true)
        XCTAssertNotNil(held.first?.senderReadAloudAt, "A change is stamped")
        XCTAssertEqual(held.first?.alsoSharedAs, [id("U", "U-1")], "The alias is added in the same pass")
        // And off again, then a packet with no choice: still off.
        _ = try send(packet("V", from: "Ada", [("one", 60_000)], readAloud: false))
        _ = try send(packet("W", from: "Ada", [("one", 60_000)]))
        XCTAssertEqual(try XCTUnwrap(margins().first).readsAloud, false)
    }

    func testAnExplicitOnWhenNothingWasTurnedOffChangesNothing() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: true))
        let held = try XCTUnwrap(margins().first)
        XCTAssertNil(held.senderReadAloud, "The held copy is left as it was")
        XCTAssertNil(held.senderReadAloudAt, "Nothing changed, so nothing is stamped")
        XCTAssertTrue(held.readsAloud)
    }

    func testAListenersOwnChoiceBeatsTheSendersTurningItBackOn() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], readAloud: false))
        var mine = try XCTUnwrap(margins().first)
        mine.listenerReadAloud = false
        try store.saveImportedCommentaryInterjection(mine)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: true))
        let held = try XCTUnwrap(margins().first)
        XCTAssertEqual(held.senderReadAloud, false, "The held copy is left as it is")
        XCTAssertEqual(held.listenerReadAloud, false)
        XCTAssertFalse(held.readsAloud)
    }

    func testARecordingHasNoChoiceToTurnBackOn() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], voiceMs: 4_000, recording: true))
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], voiceMs: 4_000, readAloud: true, recording: true))
        XCTAssertNil(try XCTUnwrap(margins().first).senderReadAloud)
    }

    func testTheSameChoiceAgainChangesNothing() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], readAloud: false))
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: false))
        let held = try XCTUnwrap(margins().first)
        XCTAssertEqual(held.senderReadAloud, false)
        XCTAssertNil(held.senderReadAloudAt, "Only a change is stamped")
    }

    func testAListenersOwnChoiceBeatsAResentFlip() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var mine = try XCTUnwrap(margins().first)
        mine.listenerReadAloud = false
        try store.saveImportedCommentaryInterjection(mine)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: false))
        _ = try send(packet("V", from: "Ada", [("one", 60_000)], readAloud: true))
        let held = try XCTUnwrap(margins().first)
        XCTAssertEqual(held.listenerReadAloud, false)
        XCTAssertNil(held.senderReadAloud, "The held copy is left as it is")
        XCTAssertEqual(held.readsAloud, false)
        XCTAssertEqual(held.alsoSharedAs?.count, 2, "The aliases still arrive")
    }

    func testAMarginWithARecordingHasNoChoiceToChange() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)], voiceMs: 4_000, recording: true))
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], voiceMs: 4_000, readAloud: false, recording: true))
        let held = try XCTUnwrap(margins().first)
        XCTAssertNil(held.senderReadAloud)
        XCTAssertEqual(held.readsAloud, false)
        XCTAssertEqual(held.alsoSharedAs?.count, 1)
    }

    func testACopyLoadedBeforeTheResendCannotUndoTheFlip() throws {
        _ = try send(packet("O", from: "Ada", [("one", 60_000)]))
        var stale = try XCTUnwrap(margins().first)
        _ = try send(packet("U", from: "Ada", [("one", 60_000)], readAloud: false))
        stale.resolution = ImportedAnchorResolution(evidenceClass: .unresolved)
        try store.saveImportedCommentaryInterjection(stale)
        XCTAssertEqual(try XCTUnwrap(margins().first).senderReadAloud, false)
    }

    func testTheFlipSurvivesInMemoryToo() throws {
        let memory = InMemorySessionRepository()
        let layer = ImportedCommentaryLayer(
            id: "layer-O", itemId: "item-1", packageDigest: "O", packageId: "package-O",
            itemIdentity: item, displayLabel: "Ada", importedAt: clock, isEnabled: true
        )
        let first = packet("O", from: "Ada", [("one", 60_000)])
        _ = try ImportedMarginResends.importLayer(layer, interjections: first.margins, repository: memory)
        var stale = try XCTUnwrap(memory.loadImportedCommentaryInterjections(layerId: "layer-O").first)
        let again = packet("U", from: "Ada", [("one", 60_000)], readAloud: false)
        let layerU = ImportedCommentaryLayer(
            id: "layer-U", itemId: "item-1", packageDigest: "U", packageId: "package-U",
            itemIdentity: item, displayLabel: "Ada", importedAt: clock.addingTimeInterval(1), isEnabled: true
        )
        _ = try ImportedMarginResends.importLayer(layerU, interjections: again.margins, repository: memory)
        try memory.saveImportedCommentaryInterjection(stale)
        stale = try XCTUnwrap(memory.loadImportedCommentaryInterjections(layerId: "layer-O").first)
        XCTAssertEqual(stale.senderReadAloud, false)
    }

    func testARecordFromBeforeThisChangeDecodesWithoutAStamp() throws {
        let margin = ImportedCommentaryInterjection(
            id: "m", layerId: "l", packageScopedId: "s", createdAt: clock,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 1), approvedTranscript: "words", senderReadAloud: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(margin), as: UTF8.self)
        XCTAssertFalse(json.contains("senderReadAloudAt"), json)
        XCTAssertNil(try JSONDecoder().decode(ImportedCommentaryInterjection.self, from: Data(json.utf8)).senderReadAloudAt)
    }

    // MARK: Report this link on a Margin held before the link (#2846)

    private let linkA = "0123456789abcdef0123456789abcdef"
    private let linkB = "fedcba9876543210fedcba9876543210"
    private let sender = "00112233445566778899aabbccddeeff"

    private func linkIds() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try layers().map { ($0.packageDigest, $0.shareLinkId ?? "-") })
    }

    func testAReShareThroughALinkGivesTheEarlierFileTheLink() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]), linkId: linkA)
        XCTAssertEqual(try linkIds(), ["O": linkA, "U": linkA])
    }

    func testAReShareWithNothingNewStillGivesTheHeldLayerTheLink() throws {
        try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]))
        XCTAssertFalse(try send(packet("O", from: "Ada", [("one", 60_000)]), linkId: linkA).isImported)
        XCTAssertEqual(try linkIds(), ["U": linkA])
    }

    func testAHeldLinkIsKeptWhenAnotherLinkBringsTheSameMargins() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]), linkId: linkA)
        try send(packet("U", from: "Ada", [("one", 60_000), ("two", 120_000)]), linkId: linkB)
        XCTAssertEqual(try linkIds(), ["O": linkA, "U": linkB])
    }

    func testALinkThatIsNotALinkIdIsNotKept() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        for bad in ["", "../x", "0123456789ABCDEF0123456789ABCDEF", String(linkA.dropLast()), linkA + "0", "https://example.com/l/" + linkA] {
            try send(packet("U", from: "Ada", [("one", 60_000)]), linkId: bad)
        }
        XCTAssertEqual(try linkIds(), ["O": "-"])
    }

    func testALinkOnlyReachesTheLayersHoldingTheRepeatedMargins() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        try send(packet("B", from: "Ada", [("other", 180_000)]))
        try send(packet("C", from: "Ben", [("one", 60_000)], person: "Ben"))
        try send(packet("U", from: "Ada", [("one", 60_000)]), linkId: linkA)
        XCTAssertEqual(try linkIds(), ["O": linkA, "B": "-", "C": "-"])
    }

    func testTheSenderIdAndTheLinkBothSurviveOneReShare() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        try send(packet("U", from: "Ada", [("one", 60_000)]), linkId: linkA, senderId: sender)
        let held = try XCTUnwrap(layers().first { $0.packageDigest == "O" })
        XCTAssertEqual(held.shareLinkId, linkA)
        XCTAssertEqual(held.senderId, sender, "the link back-fill must not save an older copy over the sender id")
    }

    func testRememberingALinkOnAHeldPacket() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        try ImportedMarginResends.rememberShareLink(linkA, onLayerWithDigest: "O", repository: store)
        XCTAssertEqual(try linkIds(), ["O": linkA])
        try ImportedMarginResends.rememberShareLink(linkB, onLayerWithDigest: "O", repository: store)
        XCTAssertEqual(try linkIds(), ["O": linkA], "the first link stays")
    }

    func testRememberingALinkIgnoresBadValuesMissingPacketsAndDeletedLayers() throws {
        try send(packet("O", from: "Ada", [("one", 60_000)]))
        for bad in [nil, "", "nope", "../" + linkA] {
            try ImportedMarginResends.rememberShareLink(bad, onLayerWithDigest: "O", repository: store)
        }
        try ImportedMarginResends.rememberShareLink(linkA, onLayerWithDigest: "no-such-packet", repository: store)
        var layer = try XCTUnwrap(layers().first)
        layer.deletedAt = clock
        try store.saveImportedCommentaryLayer(layer)
        try ImportedMarginResends.rememberShareLink(linkA, onLayerWithDigest: "O", repository: store)
        XCTAssertEqual(try linkIds(), ["O": "-"])
    }

    func testTheLinkBackFillSurvivesInMemoryToo() throws {
        let memory = InMemorySessionRepository()
        let first = packet("O", from: "Ada", [("one", 60_000)])
        let layerO = ImportedCommentaryLayer(
            id: "layer-O", itemId: "item-1", packageDigest: "O", packageId: "package-O", itemIdentity: item,
            displayLabel: "Ada", importedAt: clock, isEnabled: true)
        _ = try ImportedMarginResends.importLayer(layerO, interjections: first.margins, repository: memory)
        try ImportedMarginResends.rememberShareLink(linkA, onLayerWithDigest: "O", repository: memory)
        XCTAssertEqual(try memory.loadImportedCommentaryLayer(packageDigest: "O")?.shareLinkId, linkA)
    }

    // MARK: Text places (#3708)
    // The rows above place Margins by media time only. A Margin on a page or a transcript is placed by
    // these fields, so each one gets its own neighbouring row: the same words from the same friend,
    // one field apart, are two Margins; none apart (or only a Unicode spelling apart) is one.

    private var textPlace: PortableAnchorEvidence {
        PortableAnchorEvidence(
            anchorType: .text, startChar: 120, endChar: 160, exactText: "the harbour light", prefix: "past ", suffix: " again",
            roughPercent: 40, transcriptSegmentId: "seg-4", chapterTitle: "Harbour")
    }

    private func textPlace(
        type: AnchorType? = nil, startChar: Int? = nil, endChar: Int? = nil, exactText: String? = nil,
        prefix: String? = nil, suffix: String? = nil, roughPercent: Int? = nil, transcriptSegmentId: String? = nil,
        chapterTitle: String? = nil
    ) -> PortableAnchorEvidence {
        let base = textPlace
        return PortableAnchorEvidence(
            anchorType: type ?? base.anchorType, startChar: startChar ?? base.startChar, endChar: endChar ?? base.endChar,
            exactText: exactText ?? base.exactText, prefix: prefix ?? base.prefix, suffix: suffix ?? base.suffix,
            roughPercent: roughPercent ?? base.roughPercent, transcriptSegmentId: transcriptSegmentId ?? base.transcriptSegmentId,
            chapterTitle: chapterTitle ?? base.chapterTitle)
    }

    private func held(whenResentWith changed: PortableAnchorEvidence) throws -> Int {
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], place: textPlace))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], place: changed))
        return try margins().count
    }

    func testTheSameTextPlaceAgainIsTheMarginAlreadyHeld() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace), 1)
    }

    func testAnotherStartCharIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(startChar: 121)), 2)
    }

    func testAnotherEndCharIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(endChar: 161)), 2)
    }

    func testAnotherExactTextIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(exactText: "the harbour lights")), 2)
    }

    func testAnotherPrefixIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(prefix: "by ")), 2)
    }

    func testAnotherSuffixIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(suffix: " once more")), 2)
    }

    func testAnotherRoughPercentIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(roughPercent: 41)), 2)
    }

    func testAnotherTranscriptSegmentIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(transcriptSegmentId: "seg-5")), 2)
    }

    func testAnotherChapterTitleIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(chapterTitle: "Lighthouse")), 2)
    }

    func testAnotherAnchorTypeIsAnotherMargin() throws {
        XCTAssertEqual(try held(whenResentWith: textPlace(type: .transcript)), 2)
    }

    func testAnotherUnicodeSpellingOfTheSameTextPlaceIsNotANewMargin() throws {
        // "é" as one scalar, then as "e" and a combining accent: the same letters to a listener.
        let composed = textPlace(exactText: "caf\u{E9}", prefix: "the ", chapterTitle: "Caf\u{E9}")
        let decomposed = textPlace(exactText: "cafe\u{301}", prefix: "the ", chapterTitle: "Cafe\u{301}")
        _ = try send(packet("O", from: "Ada", [("love this", 60_000)], place: composed))
        _ = try send(packet("U", from: "Ada", [("love this", 60_000)], place: decomposed))
        XCTAssertEqual(try margins().count, 1)
    }

    // MARK: Helpers

    private struct Packet {
        let digest: String
        let label: String?
        let itemId: String?
        let margins: [ImportedCommentaryInterjection]
        let links: [MarginReplyLink]
    }

    private func id(_ digest: String, _ scoped: String) -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: digest, packageScopedId: scoped)
    }

    private static func order(_ lhs: MarginPacketIdentity, _ rhs: MarginPacketIdentity) -> Bool {
        (lhs.packageDigest, lhs.packageScopedId) < (rhs.packageDigest, rhs.packageScopedId)
    }

    /// A packet's Margins as the importer builds them: new local ids, the packet's own scoped ids.
    private func packet(
        _ digest: String, from label: String?, _ margins: [(String, Int)],
        voiceMs: Int? = nil, evidence: [String] = [], itemId: String? = "item-1", links: [MarginReplyLink] = [], provenance: Bool = true, person: String? = nil, readAloud: Bool? = nil, recording: Bool = false,
        place: PortableAnchorEvidence? = nil
    ) -> Packet {
        var occurrences: [Int: Int] = [:]
        return Packet(
            digest: digest, label: label, itemId: itemId,
            margins: margins.enumerated().map { index, margin in
                let occurrence = occurrences[margin.1, default: 0]
                occurrences[margin.1] = occurrence + 1
                let capture = "\(person ?? label ?? "")|\(margin.1)|\(occurrence)"
                if captureOrigins[capture] == nil {
                    captureOrigins[capture] = MarginShareProvenance.token(sessionId: UUID().uuidString, interjectionId: capture)
                }
                return ImportedCommentaryInterjection(
                    id: "local-\(digest)-\(index + 1)", layerId: "layer-\(digest)", packageScopedId: "\(digest)-\(index + 1)",
                    // The time the packet was made, as the app stamps it: never the same twice.
                    createdAt: clock.addingTimeInterval(Double(digest.unicodeScalars.first!.value)),
                    anchorEvidence: place ?? PortableAnchorEvidence(anchorType: .media, mediaTimeMs: margin.1, machineEvidenceAssetIds: evidence),
                    approvedTranscript: margin.0,
                    audioPath: recording ? "/tmp/\(digest)-\(index + 1).m4a" : nil,
                    audioDurationMs: voiceMs,
                    replyLinks: links.isEmpty ? nil : links,
                    shareProvenance: provenance ? captureOrigins[capture] : nil,
                    senderReadAloud: readAloud
                )
            },
            links: links
        )
    }

    private func reply(_ digest: String, parent: MarginPacketIdentity, from label: String = "Ben") -> Packet {
        let link = MarginReplyLink.replying(to: parent, parentConversationId: nil)
        return packet(digest, from: label, [("reply to \(parent.packageScopedId)", 60_000)], links: [link])
    }

    @discardableResult
    private func send(_ packet: Packet, linkId: String? = nil, senderId: String? = nil) throws -> ImportedCommentaryImportDisposition {
        let layer = ImportedCommentaryLayer(
            id: "layer-\(packet.digest)", itemId: packet.itemId, packageDigest: packet.digest, packageId: "package-\(packet.digest)",
            itemIdentity: item, displayLabel: packet.label, importedAt: clock, isEnabled: true,
            shareLinkId: linkId, senderId: senderId
        )
        clock = clock.addingTimeInterval(1)
        // The app asks the store first; a packet with a layer is a duplicate there.
        return try ImportedMarginResends.importLayer(layer, interjections: packet.margins, repository: store)
    }

    private func layers() throws -> [ImportedCommentaryLayer] {
        try ["item-1", "item-2"].flatMap { try store.loadImportedCommentaryLayers(itemId: $0) }
    }

    private func margins() throws -> [ImportedCommentaryInterjection] {
        try layers().flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }

    /// What the listener has, by sender, place and words. Layers don't count: which packet holds a Margin
    /// depends on the order they arrived in.
    private func visible() throws -> [String] {
        let labels = Dictionary(uniqueKeysWithValues: try layers().map { ($0.id, $0.displayLabel ?? "?") })
        return try margins().map {
            "\(labels[$0.layerId] ?? "?")|\($0.anchorEvidence.mediaTimeMs ?? -1)|\($0.approvedTranscript)"
        }.sorted()
    }

    private func identities(of words: String) throws -> [MarginPacketIdentity] {
        let layers = try layers()
        let margin = try XCTUnwrap(margins().first { $0.approvedTranscript == words })
        let digest = try XCTUnwrap(layers.first { $0.id == margin.layerId }).packageDigest
        return ([id(digest, margin.packageScopedId)] + (margin.alsoSharedAs ?? [])).sorted(by: Self.order)
    }

    private func graph() throws -> MarginReplyGraph {
        MarginReplyGraph.build(localMargins: [], layers: try layers(), importedMargins: try margins())
    }
}

private extension ImportedCommentaryImportDisposition {
    var isImported: Bool {
        if case .imported = self { return true }
        return false
    }
}
