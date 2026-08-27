import Foundation
import CryptoKit
import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest
import ZIPFoundation
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

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

    func testCleanupDoesNotClaimRemovalWhenEverySpokenSegmentIsFiller() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um, uh.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 150),
                .init(id: "2", text: "uh", startMs: 180, endMs: 320)
            ]
        )

        let result = DeterministicInterjectionCleanup.propose(transcript)

        XCTAssertEqual(result.cleanedTranscript, transcript.text)
        XCTAssertEqual(result.decisions.map(\.accepted), [false, false])
        XCTAssertTrue(
            DeterministicInterjectionCleanup.acceptedRemovalRanges(
                decisions: result.decisions,
                durationMs: 320
            ).isEmpty
        )
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
        try writeSilentM4A(to: audioURL)
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
        let deterministicBytes = try Data(contentsOf: firstURL)
        _ = try InterjectionPackageArchive.write(
            manifest: manifest,
            audioFiles: audioFiles,
            to: firstURL
        )
        XCTAssertEqual(try Data(contentsOf: firstURL), deterministicBytes)
        let importDirectory = root.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let replacedSentinel = importDirectory.appendingPathComponent("replaced.txt")
        try Data("replace me".utf8).write(to: replacedSentinel)
        let imported = try InterjectionPackageArchive.read(
            from: firstURL,
            extractingAudioTo: importDirectory
        )
        XCTAssertEqual(imported.manifest, firstManifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacedSentinel.path))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(imported.extractedAudioURLs["audio/margin-001.m4a"])),
            try Data(contentsOf: audioURL)
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

    func testRuntimeValidatorRejectsPrivateSourceURLAndOutOfBoundsAnchor() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateURLData = try Data(
            contentsOf: fixtureURL("invalid/interjection-packages/private-file-url.json")
        )
        let privateURLManifest = try InterjectionPackageArchive.decodeManifest(privateURLData)

        XCTAssertThrowsError(
            try InterjectionPackageArchive.write(
                manifest: privateURLManifest,
                audioFiles: [:],
                to: root.appendingPathComponent("private-url.spokenmargins")
            )
        ) { error in
            XCTAssertEqual(
                error as? InterjectionPackageArchiveError,
                .invalidManifest("source fields are absent or out of bounds")
            )
        }

        let fixture = try loadPackageFixture("minimal-article.json")
        let record = try XCTUnwrap(fixture.interjections.first)
        let invalidAnchor = PortableAnchorEvidence(anchorType: .text, roughPercent: 101)
        let invalidRecord = SharedInterjectionPackageRecord(
            packageScopedId: record.packageScopedId,
            createdAt: record.createdAt,
            anchor: invalidAnchor,
            representation: record.representation
        )
        let invalidManifest = InterjectionPackageManifest(
            packageId: fixture.packageId,
            createdAt: fixture.createdAt,
            source: fixture.source,
            interjections: [invalidRecord],
            senderDisplayLabel: fixture.senderDisplayLabel,
            suggestedRevealMode: fixture.suggestedRevealMode
        )

        XCTAssertThrowsError(
            try InterjectionPackageArchive.write(
                manifest: invalidManifest,
                audioFiles: [:],
                to: root.appendingPathComponent("invalid-anchor.spokenmargins")
            )
        ) { error in
            XCTAssertEqual(
                error as? InterjectionPackageArchiveError,
                .invalidManifest("an interjection field is absent or out of bounds")
            )
        }
    }

    func testPreviewIsIntegrityChecked() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let validURL = root.appendingPathComponent("valid.spokenmargins")
        let manifest = try InterjectionPackageArchive.write(
            manifest: loadPackageFixture("minimal-article.json"),
            audioFiles: [:],
            to: validURL
        )
        let tamperedURL = root.appendingPathComponent("tampered-preview.spokenmargins")
        try writeRawArchive(
            manifestData: InterjectionPackageArchive.encodeManifest(manifest),
            previewData: Data((InterjectionPackageArchive.previewMarkdown(manifest) + "\nTampered").utf8),
            to: tamperedURL
        )

        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(
                from: tamperedURL,
                extractingAudioTo: root.appendingPathComponent("tampered-preview-audio")
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackageArchiveError, .invalidDigest)
        }
    }

    func testPreviewEscapesUntrustedMarkdownFields() throws {
        let fixture = try loadPackageFixture("minimal-article.json")
        let record = try XCTUnwrap(fixture.interjections.first)
        let source = SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: "https://example.com/article",
            title: "[Title](https://tracker.example) <script>"
        )
        let representation = SharedInterjectionRepresentation(
            kind: .textOnly,
            approvedTranscript: "![remote](https://tracker.example/pixel) <img src=x>",
            provenance: .senderApprovedTextOnly
        )
        let manifest = InterjectionPackageManifest(
            packageId: fixture.packageId,
            createdAt: fixture.createdAt,
            source: source,
            interjections: [
                .init(
                    packageScopedId: record.packageScopedId,
                    createdAt: record.createdAt,
                    anchor: record.anchor,
                    representation: representation
                )
            ],
            senderDisplayLabel: "[Sender](https://tracker.example)"
        )

        let preview = InterjectionPackageArchive.previewMarkdown(manifest)

        XCTAssertFalse(preview.contains("![remote]"))
        XCTAssertFalse(preview.contains("<script>"))
        XCTAssertTrue(preview.contains(#"\<img"#))
        XCTAssertTrue(preview.contains(#"\!\[remote\]\(https://tracker.example/pixel\)"#))
        XCTAssertTrue(preview.contains("<https://example.com/article>"))
    }

    func testInvalidAudioCannotReplaceExportOrPartialImportDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidAudioURL = root.appendingPathComponent("invalid.m4a")
        try Data("not-audio".utf8).write(to: invalidAudioURL)
        let existingExport = root.appendingPathComponent("existing.spokenmargins")
        let existingExportData = Data("existing-package".utf8)
        try existingExportData.write(to: existingExport)

        XCTAssertThrowsError(
            try InterjectionPackageArchive.write(
                manifest: loadPackageFixture("podcast-cleaned-audio.json"),
                audioFiles: ["audio/margin-001.m4a": invalidAudioURL],
                to: existingExport
            )
        ) { error in
            XCTAssertEqual(error as? InterjectionPackageArchiveError, .invalidAudio("audio/margin-001.m4a"))
        }
        XCTAssertEqual(try Data(contentsOf: existingExport), existingExportData)

        var maliciousManifest = try loadPackageFixture("podcast-cleaned-audio.json")
        let invalidAudioData = try Data(contentsOf: invalidAudioURL)
        maliciousManifest.contentDigest = try testPackageDigest(
            manifest: maliciousManifest,
            audioData: ["audio/margin-001.m4a": invalidAudioData]
        )
        let maliciousURL = root.appendingPathComponent("malicious.spokenmargins")
        try writeRawArchive(
            manifestData: InterjectionPackageArchive.encodeManifest(maliciousManifest),
            previewData: Data(InterjectionPackageArchive.previewMarkdown(maliciousManifest).utf8),
            audioData: ["audio/margin-001.m4a": invalidAudioData],
            to: maliciousURL
        )
        let existingImport = root.appendingPathComponent("existing-import", isDirectory: true)
        try FileManager.default.createDirectory(at: existingImport, withIntermediateDirectories: true)
        let sentinel = existingImport.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try InterjectionPackageArchive.read(from: maliciousURL, extractingAudioTo: existingImport)
        ) { error in
            XCTAssertEqual(error as? InterjectionPackageArchiveError, .invalidAudio("audio/margin-001.m4a"))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existingImport.path), ["keep.txt"])
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
        let importedLayer = try XCTUnwrap(repository.importedCommentaryLayers.values.first)
        XCTAssertFalse(importedLayer.isEnabled)
        XCTAssertNil(importedLayer.revealMode)
        XCTAssertEqual(importedLayer.suggestedRevealMode, .companion)
        XCTAssertEqual(importedLayer.sourceResolutionStatus, .pending)
        XCTAssertEqual(
            repository.importedCommentaryInterjections.values.first?.resolution.evidenceClass,
            .unresolved
        )
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

    func testImportPersistsPerNoteResolutionAndDerivesLayerStatus() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try verifiedArticleContents(in: root)
        let repository = InMemorySessionRepository()
        let sourceText = "Before this passage. The durable idea that prompted this note. After this passage."

        _ = try InterjectionPackageImporter.importPackage(
            contents,
            itemId: "recipient-item",
            localSource: articleSource,
            sourceText: sourceText,
            importedAt: fixedDate,
            repository: repository,
            makeLocalID: { kind, packageID in "resolved-\(kind)-\(packageID)" }
        )

        XCTAssertEqual(repository.importedCommentaryLayers.values.first?.sourceResolutionStatus, .resolved)
        let note = try XCTUnwrap(repository.importedCommentaryInterjections.values.first)
        XCTAssertEqual(note.resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(note.resolution.localStartChar, 21)
        XCTAssertFalse(try XCTUnwrap(repository.importedCommentaryLayers.values.first).isEnabled)
    }

    func testShareRevisionIDsAreImmutableInMemoryAndSQLite() throws {
        let original = approvedRevision(
            createdAt: Date(timeIntervalSince1970: fixedDate.timeIntervalSince1970 + 0.123)
        )
        let conflicting = InterjectionShareRevision(
            id: original.id,
            interjectionId: original.interjectionId,
            itemId: original.itemId,
            sessionId: original.sessionId,
            createdAt: original.createdAt,
            approvedTranscript: "Changed after persistence.",
            anchorBefore: original.anchorBefore,
            anchorAfter: original.anchorAfter,
            status: original.status
        )
        let expectedError = SessionKitError.persistenceFailed(
            "interjection_share_revision_immutable_conflict"
        )
        let memoryRepository = InMemorySessionRepository()
        try memoryRepository.saveInterjectionShareRevision(original)
        try memoryRepository.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try memoryRepository.saveInterjectionShareRevision(conflicting)) { error in
            XCTAssertEqual(error as? SessionKitError, expectedError)
        }
        XCTAssertEqual(memoryRepository.interjectionShareRevisions[original.id], original)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqliteRepository = try SQLiteSessionStore(
            path: root.appendingPathComponent("immutable.sqlite").path
        )
        try sqliteRepository.saveInterjectionShareRevision(original)
        try sqliteRepository.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try sqliteRepository.saveInterjectionShareRevision(conflicting)) { error in
            XCTAssertEqual(error as? SessionKitError, expectedError)
        }
        let loadedRevisions = try sqliteRepository.loadInterjectionShareRevisions(
            interjectionId: original.interjectionId
        )
        XCTAssertEqual(loadedRevisions.count, 1)
        let loaded = try XCTUnwrap(loadedRevisions.first)
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(loaded.approvedTranscript, original.approvedTranscript)
        XCTAssertEqual(loaded.status, original.status)
    }

    func testSourceResolutionDistinguishesWrongAmbiguousAndContextOnly() throws {
        let package = try loadPackageFixture("minimal-article.json")
        let wrongSource = SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: "https://example.com/a-different-article",
            title: "Different"
        )
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: wrongSource, sourceText: "anything").status,
            .wrongSource
        )
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: articleSource, sourceText: nil).status,
            .contextOnly
        )
        let repeated = """
        Before this passage. The durable idea that prompted this note. After this passage.
        Before this passage. The durable idea that prompted this note. After this passage.
        """
        XCTAssertEqual(
            ImportedSourceResolver.resolve(package: package, against: articleSource, sourceText: repeated).status,
            .ambiguous
        )
    }

    func testArticleResolutionUsesExactEditionAndUniqueNormalizedFallback() throws {
        let text = "Opening. A durable idea appears here. Closing."
        let exactEditionAnchor = PortableAnchorEvidence(
            anchorType: .text,
            startChar: 9,
            endChar: 37,
            exactText: "A durable idea appears here."
        )
        let exactEdition = PortableArticleAnchorResolver.resolve(
            anchor: exactEditionAnchor,
            in: text,
            expectedExactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        XCTAssertEqual(exactEdition.evidenceClass, .articleTextVerified)
        XCTAssertEqual(exactEdition.localStartChar, 9)
        XCTAssertEqual(exactEdition.confidence, 1)

        let punctuationChanged = PortableArticleAnchorResolver.resolve(
            anchor: PortableAnchorEvidence(anchorType: .text, exactText: "the durable idea appears here"),
            in: "Before. The durable—idea, appears here! After.",
            expectedExactEditionSHA256: nil
        )
        XCTAssertEqual(punctuationChanged.evidenceClass, .articleTextVerified)
        XCTAssertEqual(punctuationChanged.confidence, 0.88)
    }

    func testNormalizedEditionMatchNeverReusesRawOffsets() {
        let senderText = "a b"
        let recipientText = "a---b"
        XCTAssertEqual(
            PortableArticleAnchorResolver.normalizedContentSHA256(senderText),
            PortableArticleAnchorResolver.normalizedContentSHA256(recipientText)
        )

        let resolution = PortableArticleAnchorResolver.resolve(
            anchor: PortableAnchorEvidence(
                anchorType: .text,
                startChar: 2,
                endChar: 3,
                exactText: "b"
            ),
            in: recipientText,
            expectedExactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(senderText)
        )

        XCTAssertEqual(resolution.evidenceClass, .articleTextVerified)
        XCTAssertEqual(resolution.localStartChar, 4)
        XCTAssertEqual(resolution.localEndChar, 5)
        XCTAssertEqual(resolution.confidence, 0.98)
    }

    func testDifferentExactEditionOfSameWorkUsesQuoteFallback() throws {
        let fixture = try loadPackageFixture("minimal-article.json")
        let senderText = "Sender edition. The durable idea that prompted this note. End."
        let recipientText = "Recipient edition. The durable idea that prompted this note. End."
        let senderSource = SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: fixture.source.canonicalURL,
            title: fixture.source.title,
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(senderText)
        )
        let localSource = SharedSourceIdentity(
            sourceType: .article,
            canonicalURL: fixture.source.canonicalURL,
            title: fixture.source.title,
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(recipientText)
        )
        let package = InterjectionPackageManifest(
            packageId: fixture.packageId,
            createdAt: fixture.createdAt,
            source: senderSource,
            interjections: fixture.interjections
        )

        let resolution = ImportedSourceResolver.resolve(
            package: package,
            against: localSource,
            sourceText: recipientText
        )

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(
            resolution.anchorsByPackageScopedId["margin-001"]?.evidenceClass,
            .articleTextVerified
        )
        XCTAssertEqual(resolution.anchorsByPackageScopedId["margin-001"]?.confidence, 0.98)
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
        decisions: [InterjectionCleanupDecision] = [],
        createdAt: Date? = nil
    ) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved",
            interjectionId: "private-note",
            itemId: "private-item",
            sessionId: "private-session",
            createdAt: createdAt ?? fixedDate,
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

    private func verifiedArticleContents(in root: URL) throws -> VerifiedInterjectionPackage {
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

    private func writeSilentM4A(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10))
        )
        buffer.frameLength = buffer.frameCapacity
        try audioFile.write(from: buffer)
        #else
        throw XCTSkip("AVFoundation is required to create the audio fixture")
        #endif
    }

    private func testPackageDigest(
        manifest: InterjectionPackageManifest,
        audioData: [String: Data]
    ) throws -> String {
        var unsigned = manifest
        unsigned.contentDigest = nil
        var hasher = SHA256()
        hasher.update(data: try InterjectionPackageArchive.encodeManifest(unsigned))
        updateTestDigest(
            &hasher,
            path: "preview.md",
            data: Data(InterjectionPackageArchive.previewMarkdown(unsigned).utf8)
        )
        for path in audioData.keys.sorted() {
            updateTestDigest(&hasher, path: path, data: audioData[path]!)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateTestDigest(_ hasher: inout SHA256, path: String, data: Data) {
        hasher.update(data: Data(path.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(SHA256.hash(data: data)))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(String(data.count).utf8))
        hasher.update(data: Data([0]))
    }

    private func writeRawArchive(
        manifestData: Data,
        previewData: Data? = Data("preview".utf8),
        audioData: [String: Data] = [:],
        to url: URL
    ) throws {
        let archive = try Archive(url: url, accessMode: .create)
        try addRawEntry(manifestData, path: "manifest.json", to: archive, compression: .deflate)
        if let previewData {
            try addRawEntry(previewData, path: "preview.md", to: archive, compression: .deflate)
        }
        for path in audioData.keys.sorted() {
            try addRawEntry(try XCTUnwrap(audioData[path]), path: path, to: archive, compression: .none)
        }
    }

    private func addRawEntry(
        _ data: Data,
        path: String,
        to archive: Archive,
        compression: CompressionMethod
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            modificationDate: Date(timeIntervalSince1970: 315_532_800),
            permissions: 0o644,
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            guard start < data.count else { return Data() }
            return data.subdata(in: start..<min(data.count, start + size))
        }
    }
}
