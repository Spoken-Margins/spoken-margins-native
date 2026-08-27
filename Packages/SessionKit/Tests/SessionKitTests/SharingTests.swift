import Foundation
import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest
import ZIPFoundation

final class SharingTests: XCTestCase {
    func testContractFixturesDecodeIntoTypedModels() throws {
        let article = try loadPackageFixture("minimal-article.json")
        let podcast = try loadPackageFixture("podcast-cleaned-audio.json")
        let revisionData = try Data(contentsOf: fixtureURL("sharing/cleanup-revision.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let revision = try decoder.decode(InterjectionShareRevision.self, from: revisionData)

        XCTAssertEqual(article.interjections.first?.representation.kind, .textOnly)
        XCTAssertNil(article.interjections.first?.representation.audioPath)
        XCTAssertEqual(podcast.interjections.first?.representation.kind, .cleanedAudioAndText)
        XCTAssertEqual(revision.cleanupPolicyVersion, DeterministicInterjectionCleanup.policyVersion)
        XCTAssertEqual(revision.status, .senderReviewPending)
    }

    func testCleanupIsDeterministicWithoutSubstringCorruptionOrPrivateCaptureMutation() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um umbrella matters.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 180),
                .init(id: "2", text: "umbrella", startMs: 220, endMs: 600),
                .init(id: "3", text: "matters.", startMs: 630, endMs: 900)
            ]
        )
        let privateCapture = transcript

        let first = DeterministicInterjectionCleanup.propose(transcript)
        let second = DeterministicInterjectionCleanup.propose(transcript)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.cleanedTranscript, "Umbrella matters.")
        XCTAssertEqual(first.decisions.map(\.kind), [.filler])
        XCTAssertEqual(transcript, privateCapture)
        XCTAssertEqual(transcript.text, "Um umbrella matters.")
    }

    func testCleanupPreservesSemanticYouKnowAndRestoresIndividualDecision() throws {
        let semantic = AlignedInterjectionTranscript(
            text: "You know the answer.",
            segments: [
                .init(id: "1", text: "You", startMs: 0, endMs: 100),
                .init(id: "2", text: "know", startMs: 120, endMs: 220),
                .init(id: "3", text: "the", startMs: 240, endMs: 300),
                .init(id: "4", text: "answer.", startMs: 320, endMs: 500)
            ]
        )
        XCTAssertEqual(DeterministicInterjectionCleanup.propose(semantic).cleanedTranscript, semantic.text)

        let filler = AlignedInterjectionTranscript(
            text: "Uh a clear thought.",
            segments: [
                .init(id: "1", text: "Uh", startMs: 0, endMs: 150),
                .init(id: "2", text: "a", startMs: 200, endMs: 240),
                .init(id: "3", text: "clear", startMs: 260, endMs: 400),
                .init(id: "4", text: "thought.", startMs: 420, endMs: 650)
            ]
        )
        let initial = DeterministicInterjectionCleanup.propose(filler)
        let decision = try XCTUnwrap(initial.decisions.first)
        let restored = DeterministicInterjectionCleanup.propose(
            filler,
            restoredDecisionIds: [decision.id]
        )
        XCTAssertEqual(restored.cleanedTranscript, filler.text)
        XCTAssertEqual(restored.decisions.first?.accepted, false)
    }

    func testAnchorContextKeepsNearestBoundedEvidence() {
        let context = BoundedAnchorContext.select(
            before: String(repeating: "a", count: 600) + " BEFORE_NEAR ",
            after: " AFTER_NEAR " + String(repeating: "z", count: 600)
        )

        XCTAssertEqual(context.before.count, BoundedAnchorContext.maximumCharactersPerSide)
        XCTAssertEqual(context.after.count, BoundedAnchorContext.maximumCharactersPerSide)
        XCTAssertTrue(context.before.hasSuffix("BEFORE_NEAR"))
        XCTAssertTrue(context.after.hasPrefix("AFTER_NEAR"))
    }

    func testBuilderIncludesOnlySelectedReviewedRepresentationAndMinimizesData() throws {
        let privatePath = "/private/Library/secret-cleaned.m4a"
        let revision = approvedRevision(
            cleanedAudioPath: privatePath,
            decisions: [
                .init(
                    id: "private-decision",
                    kind: .filler,
                    startMs: 0,
                    endMs: 100,
                    originalText: "API_KEY_SECRET",
                    accepted: true
                )
            ]
        )
        let prepared = try InterjectionPackageBuilder.prepare(
            packageId: "package-selected",
            createdAt: fixedDate,
            conversationId: "conversation-selected",
            source: articleSource,
            selections: [
                ReviewedInterjectionSelection(
                    packageScopedId: "package-note",
                    revision: revision,
                    anchor: PortableAnchorEvidence(
                        anchorType: .text,
                        startChar: 10,
                        endChar: 20,
                        exactText: "bounded excerpt"
                    ),
                    representation: .textOnly
                )
            ]
        )
        let encoded = try InterjectionPackageArchive.encodeManifest(prepared.manifest)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(prepared.audioFiles.isEmpty)
        XCTAssertNil(prepared.manifest.interjections.first?.representation.audioPath)
        XCTAssertTrue(prepared.manifest.redactions.provesDefaultMinimization)
        XCTAssertFalse(json.contains(privatePath))
        XCTAssertFalse(json.contains("API_KEY_SECRET"))
        XCTAssertFalse(json.contains("cleanedAudioPath"))
        XCTAssertFalse(json.contains("diagnosticPayload"))
        XCTAssertFalse(json.contains(#""fullSourceText":"#))
        XCTAssertFalse(json.contains(#""rawTranscript":"#))
    }

    func testBuilderRejectsDraftRevisionAndMismatchedAudioSelection() throws {
        let draft = InterjectionShareRevision(
            id: "draft",
            interjectionId: "private-note",
            itemId: "private-item",
            sessionId: "private-session",
            createdAt: fixedDate,
            approvedTranscript: "Reviewed",
            anchorBefore: "Before",
            anchorAfter: "After"
        )
        XCTAssertThrowsError(
            try InterjectionPackageBuilder.prepare(
                packageId: "package",
                createdAt: fixedDate,
                conversationId: "conversation",
                source: articleSource,
                selections: [
                    .init(
                        packageScopedId: "note",
                        revision: draft,
                        anchor: .init(anchorType: .text),
                        representation: .textOnly
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackagePreparationError, .unapprovedRevision("draft"))
        }

        let reviewed = approvedRevision(cleanedAudioPath: "/tmp/right.m4a")
        XCTAssertThrowsError(
            try InterjectionPackageBuilder.prepare(
                packageId: "package",
                createdAt: fixedDate,
                conversationId: "conversation",
                source: articleSource,
                selections: [
                    .init(
                        packageScopedId: "note",
                        revision: reviewed,
                        anchor: .init(anchorType: .text),
                        representation: .cleanedAudio(sourceURL: URL(fileURLWithPath: "/tmp/wrong.m4a"))
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackagePreparationError, .cleanedAudioMismatch(reviewed.id))
        }
    }

    func testBuilderUsesArchiveRelativePathOnlyForExplicitCleanedAudioSelection() throws {
        let localURL = URL(fileURLWithPath: "/private/Library/reviewed.m4a")
        let prepared = try InterjectionPackageBuilder.prepare(
            packageId: "package-audio",
            createdAt: fixedDate,
            conversationId: "conversation-audio",
            source: articleSource,
            selections: [
                .init(
                    packageScopedId: "selected-note",
                    revision: approvedRevision(cleanedAudioPath: localURL.path),
                    anchor: .init(anchorType: .text),
                    representation: .cleanedAudio(sourceURL: localURL)
                )
            ]
        )

        let archivePath = try XCTUnwrap(prepared.manifest.interjections.first?.representation.audioPath)
        XCTAssertEqual(archivePath, "audio/interjection-0001.m4a")
        XCTAssertEqual(prepared.audioFiles, [archivePath: localURL])
        XCTAssertFalse(try String(decoding: InterjectionPackageArchive.encodeManifest(prepared.manifest), as: UTF8.self)
            .contains(localURL.path))
    }

    func testPackageDigestAndArchiveRoundTripAreDeterministic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("reviewed.m4a")
        try Data("reviewed-cleaned-audio".utf8).write(to: audioURL)
        let manifest = try loadPackageFixture("podcast-cleaned-audio.json")
        let audioFiles = ["audio/margin-001.m4a": audioURL]
        let firstURL = root.appendingPathComponent("first.spokenmargins")
        let secondURL = root.appendingPathComponent("second.spokenmargins")

        let firstManifest = try InterjectionPackageArchive.write(
            manifest: manifest,
            audioFiles: audioFiles,
            to: firstURL
        )
        let secondManifest = try InterjectionPackageArchive.write(
            manifest: manifest,
            audioFiles: audioFiles,
            to: secondURL
        )

        XCTAssertEqual(firstManifest.contentDigest, secondManifest.contentDigest)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
        let imported = try InterjectionPackageArchive.read(
            from: firstURL,
            extractingAudioTo: root.appendingPathComponent("imported", isDirectory: true)
        )
        XCTAssertEqual(imported.manifest, firstManifest)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(imported.extractedAudioURLs["audio/margin-001.m4a"])),
            Data("reviewed-cleaned-audio".utf8)
        )
    }

    func testArchiveRejectsTamperedDigestMalformedJSONAndMalformedArchive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var tampered = try loadPackageFixture("minimal-article.json")
        tampered.contentDigest = String(repeating: "0", count: 64)
        let tamperedURL = root.appendingPathComponent("tampered.spokenmargins")
        try writeRawArchive(manifestData: InterjectionPackageArchive.encodeManifest(tampered), to: tamperedURL)
        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(
                from: tamperedURL,
                extractingAudioTo: root.appendingPathComponent("tampered-audio")
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackageArchiveError, .invalidDigest)
        }

        let malformedJSONURL = root.appendingPathComponent("malformed-json.spokenmargins")
        try writeRawArchive(manifestData: Data("not-json".utf8), to: malformedJSONURL)
        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(
                from: malformedJSONURL,
                extractingAudioTo: root.appendingPathComponent("malformed-json-audio")
            )
        ) { error in
            guard case .invalidManifest = error as? InterjectionPackageArchiveError else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }

        let malformedArchiveURL = root.appendingPathComponent("malformed-archive.spokenmargins")
        try Data("not-an-archive".utf8).write(to: malformedArchiveURL)
        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(
                from: malformedArchiveURL,
                extractingAudioTo: root.appendingPathComponent("malformed-archive-audio")
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackageArchiveError, .malformedArchive)
        }
    }

    func testArchiveRejectsUnsupportedSchemaVersionBeforeImport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var unsupported = try loadPackageFixture("../invalid/interjection-packages/unsupported-schema.json")
        unsupported.contentDigest = String(repeating: "0", count: 64)
        let packageURL = root.appendingPathComponent("unsupported.spokenmargins")
        try writeRawArchive(manifestData: InterjectionPackageArchive.encodeManifest(unsupported), to: packageURL)

        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(
                from: packageURL,
                extractingAudioTo: root.appendingPathComponent("audio")
            )
        ) { error in
            XCTAssertEqual(
                error as? InterjectionPackageArchiveError,
                .unsupportedSchema("spoken-margins.interjection-package.v999")
            )
        }
    }

    func testWriterRejectsFixtureWithMissingPrivacyProof() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try Data(contentsOf: fixtureURL("invalid/interjection-packages/privacy-redaction-disabled.json"))
        let manifest = try InterjectionPackageArchive.decodeManifest(data)

        XCTAssertThrowsError(
            try InterjectionPackageArchive.write(
                manifest: manifest,
                audioFiles: [:],
                to: root.appendingPathComponent("unsafe.spokenmargins")
            )
        ) { error in
            XCTAssertEqual(
                error as? InterjectionPackageArchiveError,
                .invalidManifest("required redactions are not asserted")
            )
        }
    }

    func testImportMapsPackageIDsToDistinctRecipientLocalIDsAndIsIdempotent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try verifiedArticleContents(in: root)
        let repository = InMemorySessionRepository()
        let idProvider: InterjectionPackageImporter.LocalIDProvider = { kind, packageID in
            "recipient-\(kind)-\(packageID)"
        }

        let first = try InterjectionPackageImporter.importPackage(
            contents,
            itemId: "recipient-item",
            importedAt: fixedDate,
            repository: repository,
            makeLocalID: idProvider
        )
        let second = try InterjectionPackageImporter.importPackage(
            contents,
            itemId: "recipient-item",
            importedAt: fixedDate,
            repository: repository,
            makeLocalID: idProvider
        )

        XCTAssertEqual(
            first,
            .imported(
                layerId: "recipient-layer-package-article-001",
                interjectionIds: ["recipient-interjection-margin-001"]
            )
        )
        XCTAssertEqual(second, .duplicate(existingLayerId: "recipient-layer-package-article-001"))
        XCTAssertNotEqual(repository.importedCommentaryLayers.values.first?.id, "package-article-001")
        XCTAssertNotEqual(repository.importedCommentaryInterjections.values.first?.id, "margin-001")
        XCTAssertEqual(repository.importedCommentaryLayers.count, 1)
        XCTAssertEqual(repository.importedCommentaryInterjections.count, 1)
        XCTAssertTrue(repository.interjections.isEmpty)
    }

    func testSQLitePersistsDistinctLayerAndDuplicateResultWithoutMigrationLoss() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try verifiedArticleContents(in: root)
        let databaseURL = root.appendingPathComponent("session.sqlite")
        let repository = try SQLiteSessionStore(path: databaseURL.path)
        let idProvider: InterjectionPackageImporter.LocalIDProvider = { kind, packageID in
            "sqlite-\(kind)-\(packageID)"
        }

        let first = try InterjectionPackageImporter.importPackage(
            contents,
            itemId: "recipient-item",
            importedAt: fixedDate,
            repository: repository,
            makeLocalID: idProvider
        )
        let second = try InterjectionPackageImporter.importPackage(
            contents,
            itemId: "recipient-item",
            importedAt: fixedDate,
            repository: repository,
            makeLocalID: idProvider
        )

        XCTAssertEqual(
            first,
            .imported(
                layerId: "sqlite-layer-package-article-001",
                interjectionIds: ["sqlite-interjection-margin-001"]
            )
        )
        XCTAssertEqual(second, .duplicate(existingLayerId: "sqlite-layer-package-article-001"))
        XCTAssertEqual(try repository.loadImportedCommentaryLayers(itemId: "recipient-item").count, 1)
        XCTAssertEqual(
            try repository.loadImportedCommentaryInterjections(layerId: "sqlite-layer-package-article-001").count,
            1
        )
        XCTAssertEqual(try repository.quarantinedRecordCount(), 0)
    }

    func testSourceResolutionDistinguishesWrongAmbiguousAndContextOnly() throws {
        let package = try loadPackageFixture("minimal-article.json")
        let wrongSource = SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: "https://example.com/a-different-article",
            title: "Different"
        )
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: wrongSource, sourceText: "anything"),
            .wrongSource
        )
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: articleSource, sourceText: nil),
            .contextOnly
        )
        let repeated = """
        Before this passage. The durable idea that prompted this note. After this passage.
        Before this passage. The durable idea that prompted this note. After this passage.
        """
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: articleSource, sourceText: repeated),
            .ambiguous
        )
    }

    func testArticleResolutionUsesExactEditionAndUniqueNormalizedFallback() throws {
        let text = "Opening. A durable idea appears here. Closing."
        let exactEditionAnchor = PortableAnchorEvidence(
            anchorType: .text,
            startChar: 9,
            endChar: 37,
            exactText: "stale sender wording"
        )
        let exactEdition = PortableArticleAnchorResolver.resolve(
            anchor: exactEditionAnchor,
            in: text,
            expectedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text)
        )
        XCTAssertEqual(exactEdition.evidenceClass, .articleTextVerified)
        XCTAssertEqual(exactEdition.localStartChar, 9)
        XCTAssertEqual(exactEdition.confidence, 1)

        let punctuationChanged = PortableArticleAnchorResolver.resolve(
            anchor: PortableAnchorEvidence(anchorType: .text, exactText: "the durable idea appears here"),
            in: "Before. The durable—idea, appears here! After.",
            expectedContentSHA256: nil
        )
        XCTAssertEqual(punctuationChanged.evidenceClass, .articleTextVerified)
        XCTAssertEqual(punctuationChanged.confidence, 0.88)
    }

    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_777_000_000)
    }

    private var articleSource: SharedSourceIdentity {
        SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: "https://example.com/article",
            title: "A Useful Article"
        )
    }

    private func approvedRevision(
        cleanedAudioPath: String? = nil,
        decisions: [InterjectionCleanupDecision] = []
    ) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved",
            interjectionId: "private-note",
            itemId: "private-item",
            sessionId: "private-session",
            createdAt: fixedDate,
            approvedTranscript: "A sender-reviewed thought.",
            cleanedAudioPath: cleanedAudioPath,
            cleanedAudioDurationMs: cleanedAudioPath == nil ? nil : 1_000,
            decisions: decisions,
            anchorBefore: String(repeating: "b", count: 600) + " before-near",
            anchorAfter: "after-near " + String(repeating: "a", count: 600),
            status: .senderApproved
        )
    }

    private func loadPackageFixture(_ name: String) throws -> InterjectionPackageManifest {
        let data = try Data(contentsOf: fixtureURL("interjection-packages/\(name)"))
        return try InterjectionPackageArchive.decodeManifest(data)
    }

    private func fixtureURL(_ path: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Contracts/fixtures/\(path)")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func verifiedArticleContents(in root: URL) throws -> InterjectionPackageArchiveContents {
        let packageURL = root.appendingPathComponent("verified.spokenmargins")
        _ = try InterjectionPackageArchive.write(
            manifest: loadPackageFixture("minimal-article.json"),
            audioFiles: [:],
            to: packageURL
        )
        return try InterjectionPackageArchive.read(
            from: packageURL,
            extractingAudioTo: root.appendingPathComponent("verified-audio")
        )
    }

    private func writeRawArchive(manifestData: Data, to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifestData.count),
            modificationDate: Date(timeIntervalSince1970: 315_532_800),
            permissions: 0o644,
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            guard start < manifestData.count else { return Data() }
            return manifestData.subdata(in: start..<min(manifestData.count, start + size))
        }
    }
}
