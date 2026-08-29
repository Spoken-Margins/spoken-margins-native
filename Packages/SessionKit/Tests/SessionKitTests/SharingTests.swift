import CryptoKit
import Foundation
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
    func testCleanupIsDeterministicAndDoesNotMutatePrivateCapture() {
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
    }

    func testCleanupPreservesSemanticYouKnowAndSupportsPerEditUndo() throws {
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
        let restored = DeterministicInterjectionCleanup.propose(filler, restoredDecisionIds: [decision.id])
        XCTAssertEqual(restored.cleanedTranscript, filler.text)
        XCTAssertEqual(restored.decisions.first?.accepted, false)
    }

    func testCleanupShortensLongPauseButNeverDeletesAllSpeech() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um uh.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 150),
                .init(id: "2", text: "uh", startMs: 1_200, endMs: 1_350)
            ]
        )
        let result = DeterministicInterjectionCleanup.propose(transcript)
        XCTAssertEqual(result.cleanedTranscript, transcript.text)
        XCTAssertEqual(result.decisions.filter { $0.kind == .filler }.map(\.accepted), [false, false])
        XCTAssertEqual(result.decisions.first { $0.kind == .longPause }?.startMs, 400)
    }

    func testAnchorContextKeepsNearestBoundedEvidenceAndMachineReferences() {
        let anchor = PortableAnchorEvidence(
            anchorType: .transcript,
            exactText: String(repeating: "e", count: 1_200),
            prefix: String(repeating: "b", count: 600) + "near",
            suffix: "near" + String(repeating: "a", count: 600),
            mediaTimeMs: 2_000,
            roughPercent: 120,
            machineEvidenceAssetIds: ["signature-pre"]
        ).bounded()
        XCTAssertEqual(anchor.exactText?.count, 1_000)
        XCTAssertEqual(anchor.prefix?.count, 500)
        XCTAssertTrue(anchor.prefix?.hasSuffix("near") == true)
        XCTAssertEqual(anchor.suffix?.count, 500)
        XCTAssertTrue(anchor.suffix?.hasPrefix("near") == true)
        XCTAssertEqual(anchor.roughPercent, 100)
        XCTAssertEqual(anchor.machineEvidenceAssetIds, ["signature-pre"])
    }

    func testBuilderProducesFinalEnvelopeAndTextCommentaryArtifact() throws {
        let prepared = try textPreparedPackage()
        XCTAssertEqual(prepared.manifest.schemaVersion, SpokenMarginsPackageArchive.schemaVersion)
        XCTAssertEqual(prepared.manifest.artifacts.map(\.kind), [SpokenMarginsArtifactKind.commentaryLayer])
        XCTAssertTrue(prepared.manifest.assets.isEmpty)
        XCTAssertTrue(prepared.assetFiles.isEmpty)
        let data = try XCTUnwrap(prepared.artifactData["artifacts/commentary-layer.json"])
        let layer = try JSONDecoder.iso8601.decode(SharedCommentaryLayerArtifact.self, from: data)
        XCTAssertEqual(layer.interjections.first?.defaultRepresentation?.kind, .textOnly)
        XCTAssertTrue(prepared.manifest.redactions.provesDefaultMinimization)
        XCTAssertFalse(String(decoding: try SpokenMarginsPackageArchive.encodeManifest(prepared.manifest), as: UTF8.self).contains("private-note"))
    }

    func testBuilderIncludesOnlyExplicitlySelectedOriginalOrCleanedVoice() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.m4a")
        let cleanedURL = root.appendingPathComponent("cleaned.m4a")
        try writeSilentM4A(to: originalURL)
        try writeSilentM4A(to: cleanedURL)

        let original = try SpokenMarginsPackageBuilder.prepare(
            packageId: "original-package",
            createdAt: fixedDate,
            source: articleSource,
            selections: [.init(
                packageScopedId: "margin-original",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text),
                representation: .originalAudio(sourceURL: originalURL, durationMs: 100)
            )]
        )
        XCTAssertEqual(original.manifest.assets.first?.role, SpokenMarginsAssetRole.originalVoice)
        XCTAssertEqual(original.assetFiles.values.first, originalURL)

        let cleaned = try SpokenMarginsPackageBuilder.prepare(
            packageId: "cleaned-package",
            createdAt: fixedDate,
            source: articleSource,
            selections: [.init(
                packageScopedId: "margin-cleaned",
                revision: approvedRevision(cleanedAudioPath: cleanedURL.path),
                anchor: .init(anchorType: .text),
                representation: .cleanedAudio(sourceURL: cleanedURL)
            )]
        )
        XCTAssertEqual(cleaned.manifest.assets.first?.role, SpokenMarginsAssetRole.cleanedVoice)
        XCTAssertFalse(String(decoding: try SpokenMarginsPackageArchive.encodeManifest(cleaned.manifest), as: UTF8.self).contains(cleanedURL.path))
    }

    func testBuilderRejectsDraftDuplicateAndMismatchedCleanedAudio() throws {
        let draft = InterjectionShareRevision(
            id: "draft", interjectionId: "private", itemId: "item", sessionId: "session",
            createdAt: fixedDate, approvedTranscript: "Draft", anchorBefore: "", anchorAfter: ""
        )
        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, source: articleSource,
            selections: [.init(packageScopedId: "a", revision: draft, anchor: .init(anchorType: .text), representation: .textOnly)]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .unapprovedRevision("draft")) }

        let approved = approvedRevision(cleanedAudioPath: "/tmp/right.m4a")
        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, source: articleSource,
            selections: [.init(packageScopedId: "a", revision: approved, anchor: .init(anchorType: .text), representation: .cleanedAudio(sourceURL: URL(fileURLWithPath: "/tmp/wrong.m4a")))]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .cleanedAudioMismatch(approved.id)) }

        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, source: articleSource,
            selections: [
                .init(packageScopedId: "same", revision: approvedRevision(), anchor: .init(anchorType: .text), representation: .textOnly),
                .init(packageScopedId: "same", revision: approvedRevision(), anchor: .init(anchorType: .text), representation: .textOnly)
            ]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .duplicatePackageScopedId("same")) }
    }

    func testArchiveRoundTripAndBytesAreDeterministic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try textPreparedPackage()
        let firstURL = root.appendingPathComponent("first.spokenmargins")
        let secondURL = root.appendingPathComponent("second.spokenmargins")
        let first = try SpokenMarginsPackageArchive.write(prepared, to: firstURL)
        let second = try SpokenMarginsPackageArchive.write(prepared, to: secondURL)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))

        let verified = try SpokenMarginsPackageArchive.read(
            from: firstURL,
            extractingAssetsTo: root.appendingPathComponent("assets")
        )
        XCTAssertEqual(verified.manifest, first)
        XCTAssertEqual(verified.commentaryLayers.first?.interjections.first?.packageScopedId, "margin-001")
        XCTAssertTrue(verified.extractedAssetURLs.isEmpty)
    }

    func testPortableListeningMapProposalRoundTripsButDoesNotActivate() throws {
        let proposal = PortableListeningMapProposalArtifact(
            id: "proposal-1",
            createdAt: fixedDate,
            generator: "hand-authored-fixture",
            scenes: [.init(
                id: "scene-1", order: 0, title: "Opening", summaryText: "The speaker frames the question.",
                summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: .init(anchorType: .transcript, exactText: "opening"),
                endAnchor: .init(anchorType: .transcript, exactText: "question")
            )]
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "map-package", createdAt: fixedDate, source: podcastSource,
            selections: [.init(packageScopedId: "margin-001", revision: approvedRevision(), anchor: .init(anchorType: .media, mediaTimeMs: 5_000), representation: .textOnly)],
            mapProposals: [proposal]
        )
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("map.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(verified.listeningMapProposals, [proposal])
        XCTAssertEqual(verified.manifest.artifacts.last?.required, false)
    }

    func testUnknownOptionalArtifactIsSkippedAndUnknownRequiredArtifactIsRejected() throws {
        let base = try textPreparedPackage()
        var optionalManifest = base.manifest
        optionalManifest.artifacts.append(.init(
            id: "future", kind: "future_artifact", schemaVersion: "future.v1",
            path: "artifacts/future.json", required: false
        ))
        var optionalData = base.artifactData
        optionalData["artifacts/future.json"] = Data("{}".utf8)
        let optionalPrepared = PreparedSpokenMarginsPackage(manifest: optionalManifest, artifactData: optionalData, assetFiles: [:])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let optionalURL = root.appendingPathComponent("optional.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(optionalPrepared, to: optionalURL)
        XCTAssertNoThrow(try SpokenMarginsPackageArchive.read(from: optionalURL, extractingAssetsTo: root.appendingPathComponent("optional-assets")))

        var requiredManifest = base.manifest
        requiredManifest.artifacts.append(.init(
            id: "future", kind: "future_artifact", schemaVersion: "future.v1",
            path: "artifacts/future.json", required: true
        ))
        let requiredPrepared = PreparedSpokenMarginsPackage(manifest: requiredManifest, artifactData: optionalData, assetFiles: [:])
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(requiredPrepared, to: root.appendingPathComponent("required.spokenmargins"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .unsupportedRequiredCapability("future_artifact"))
        }
    }

    func testArchiveRejectsPreReleaseV1AndTamperedArtifact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.spokenmargins")
        try writeRawArchive(entries: [
            "manifest.json": Data(#"{"schemaVersion":"spoken-margins.interjection-package.v1"}"#.utf8),
            "preview.md": Data()
        ], to: oldURL)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: oldURL, extractingAssetsTo: root.appendingPathComponent("old-assets"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .unsupportedSchema("spoken-margins.interjection-package.v1"))
        }

        let goodURL = root.appendingPathComponent("good.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(textPreparedPackage(), to: goodURL)
        var entries = try readRawArchive(goodURL)
        entries["artifacts/commentary-layer.json"] = Data("{}".utf8)
        let tamperedURL = root.appendingPathComponent("tampered.spokenmargins")
        try writeRawArchive(entries: entries, to: tamperedURL)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: tamperedURL, extractingAssetsTo: root.appendingPathComponent("tampered-assets"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .invalidDigest)
        }
    }

    func testImportUsesDistinctLocalIDsAndIsIdempotentInMemoryAndSQLite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try verifiedTextPackage(in: root)
        let memory = InMemorySessionRepository()
        let provider: SpokenMarginsPackageImporter.LocalIDProvider = { kind, packageID in "recipient-\(kind)-\(packageID)" }
        let first = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: memory, makeLocalID: provider)
        let second = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: memory, makeLocalID: provider)
        XCTAssertEqual(first, .imported(layerId: "recipient-layer-package-article-001", interjectionIds: ["recipient-interjection-margin-001"]))
        XCTAssertEqual(second, .duplicate(existingLayerId: "recipient-layer-package-article-001"))
        XCTAssertTrue(memory.interjections.isEmpty)
        XCTAssertFalse(try XCTUnwrap(memory.importedCommentaryLayers.values.first).isEnabled)

        let sqlite = try SQLiteSessionStore(path: root.appendingPathComponent("sharing.sqlite").path)
        _ = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: sqlite, makeLocalID: provider)
        XCTAssertEqual(try sqlite.loadImportedCommentaryLayers(itemId: "recipient-item").count, 1)
        XCTAssertEqual(try sqlite.loadImportedCommentaryInterjections(layerId: "recipient-layer-package-article-001").count, 1)
        XCTAssertEqual(try sqlite.quarantinedRecordCount(), 0)
    }

    func testArticleResolverDistinguishesWrongAmbiguousAndVerified() throws {
        let prepared = try textPreparedPackage()
        let layerData = try XCTUnwrap(prepared.artifactData["artifacts/commentary-layer.json"])
        let layer = try JSONDecoder.iso8601.decode(SharedCommentaryLayerArtifact.self, from: layerData)
        let wrong = SharedSourceIdentity(sourceType: .article, canonicalURL: "https://example.com/wrong", title: "Wrong")
        XCTAssertEqual(ImportedSourceResolver.resolve(source: prepared.manifest.source, interjections: layer.interjections, against: wrong, sourceText: "anything").status, .wrongSource)
        XCTAssertEqual(ImportedSourceResolver.resolve(source: prepared.manifest.source, interjections: layer.interjections, against: articleSource, sourceText: nil).status, .contextOnly)
        let repeated = "Before this passage. The durable idea that prompted this note. After this passage. Before this passage. The durable idea that prompted this note. After this passage."
        XCTAssertEqual(ImportedSourceResolver.resolve(source: prepared.manifest.source, interjections: layer.interjections, against: articleSource, sourceText: repeated).status, .ambiguous)
        let unique = "Before this passage. The durable idea that prompted this note. After this passage."
        let resolved = ImportedSourceResolver.resolve(source: prepared.manifest.source, interjections: layer.interjections, against: articleSource, sourceText: unique)
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.anchorsByPackageScopedId["margin-001"]?.evidenceClass, .articleTextVerified)
    }

    func testShareRevisionIDsRemainImmutableInMemoryAndSQLite() throws {
        let original = approvedRevision()
        let conflicting = InterjectionShareRevision(
            id: original.id, interjectionId: original.interjectionId, itemId: original.itemId,
            sessionId: original.sessionId, createdAt: original.createdAt, approvedTranscript: "Changed",
            anchorBefore: original.anchorBefore, anchorAfter: original.anchorAfter, status: original.status
        )
        let expected = SessionKitError.persistenceFailed("interjection_share_revision_immutable_conflict")
        let memory = InMemorySessionRepository()
        try memory.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try memory.saveInterjectionShareRevision(conflicting)) { XCTAssertEqual($0 as? SessionKitError, expected) }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try SQLiteSessionStore(path: root.appendingPathComponent("immutable.sqlite").path)
        try sqlite.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try sqlite.saveInterjectionShareRevision(conflicting)) { XCTAssertEqual($0 as? SessionKitError, expected) }
    }

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_777_000_000) }
    private var articleSource: SharedSourceIdentity {
        SharedSourceIdentity(sourceType: .article, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }
    private var podcastSource: SharedSourceIdentity {
        SharedSourceIdentity(
            sourceType: .podcast, canonicalURL: "https://example.com/episodes/one", feedURL: "https://example.com/feed.xml",
            title: "Episode One", publisher: "Example", showTitle: "Example Show", episodeGUID: "episode-one",
            enclosureURL: "https://example.com/audio/one.mp3", durationMs: 3_600_000, languageCode: "en"
        )
    }

    private func approvedRevision(cleanedAudioPath: String? = nil) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
            cleanedAudioPath: cleanedAudioPath, cleanedAudioDurationMs: cleanedAudioPath == nil ? nil : 100,
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
    }

    private func textPreparedPackage() throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-article-001", createdAt: fixedDate, source: articleSource,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
    }

    private func verifiedTextPackage(in root: URL) throws -> VerifiedSpokenMarginsPackage {
        let url = root.appendingPathComponent("verified.spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(textPreparedPackage(), to: url)
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("verified-assets"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpokenMarginsSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSilentM4A(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10)))
        buffer.frameLength = buffer.frameCapacity
        try audioFile.write(from: buffer)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func readRawArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }

    private func writeRawArchive(entries: [String: Data], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for path in entries.keys.sorted() {
            let data = try XCTUnwrap(entries[path])
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o644,
                compressionMethod: path.hasPrefix("assets/") ? .none : .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
