import Foundation
@testable import SessionKit
@testable import SessionKitPersistence

/// The tables the first fixture left empty (#2513): jobs, manifests, downloads, offline assets, imported layers, canonical
/// sources, structured documents and the mapped podcast's episode-map artifacts. Everything is derived from the same
/// seed and written after the first fixture, so the original rows (and the numbers measured on them) do not move.
///
/// Where the shapes come from: the owner's Library has 319 items, 361 sessions, 26 followed sources and one mapped
/// podcast (diagnostics, 2026-10-20), and every count below is a stated fraction of those. The repository holds no
/// export of how many jobs, manifests, downloads or imported layers the owner's database has, so these fractions are
/// assumptions, written down here so one change fixes them when a Mac-side count arrives:
/// - podcast downloads: one per podcast item (`items / 12`); 3 of every 4 finished, the rest downloading or failed;
/// - prepared audio: a manifest for every 4th article, one chunk per ~1.5 KB of text (a few hundred bytes of
///   metadata per chunk), and an owned offline asset beside it;
/// - audio preparation jobs: `items / 25` queued, episode-map jobs `items / 100`, one AI job per 10 sessions;
/// - imported layers: one per 4 followed sources, 12 shared Margins each, on distinct articles;
/// - canonical source packages for every 2nd article and structured documents for every 6th (a PDF), each holding the
///   article's whole text, so those tables are about as big as the text they came from;
/// - the mapped podcast also gets a resolved map projection, two portable proposals, a fingerprint spine and a phrase
///   sketch; two other podcasts get publisher audio, community map uploads and offline assets.
/// No byte of the owner's own data is used: every string is the fixture's seeded prose.
extension LibraryFixture {
    /// Counts the extra tables hold at this scale, so a test can check the seeding without reading every row.
    struct TableCounts: Equatable {
        var downloads = 0, manifests = 0, preparationJobs = 0, episodeMapJobs = 0, aiJobs = 0, offlineAssets = 0
        var reservations = 0, layers = 0, sharedMargins = 0, canonicalSources = 0, structuredDocuments = 0
        var collections = 0, publisherAudio = 0, communityUploads = 0, shareRevisions = 0
    }

    /// A podcast item other than the mapped one (index 0): index 1 and 2 carry publisher audio and a community upload.
    static func podcastItemId(_ index: Int) -> String { "item-\(index)" }

    @discardableResult
    func writeBackgroundTables(_ store: SQLiteSessionStore, epoch: Date, random: inout SplitMix64) throws -> TableCounts {
        var counts = TableCounts()
        let podcasts = max(1, scale.items / 12)
        let articles = Array(itemIds.dropFirst(podcasts))
        let signature = TTSRenderSignature(
            engine: "kitten", modelRevision: "1", assetManifestHash: String(repeating: "a", count: 64),
            voiceStyleHash: String(repeating: "b", count: 64), synthesisParametersHash: String(repeating: "c", count: 64),
            normalizationVersion: "norm.v1", chunkingVersion: "chunk.v1", digest: String(repeating: "d", count: 64))

        // Podcast downloads and their audio on disk (an owned offline asset each).
        for index in 0..<podcasts {
            let itemId = itemIds[index]
            let state: PodcastDownloadState = index % 4 == 1 ? .downloading : index % 12 == 3 ? .failed : .availableOffline
            try store.savePodcastDownload(PodcastDownloadRecord(
                id: "download-\(itemId)", itemId: itemId, remoteURL: "https://cdn.example.com/episodes/\(itemId).mp3",
                localRelativePath: state == .availableOffline ? "Podcasts/\(itemId).mp3" : nil, state: state,
                bytesWritten: 40_000_000 + Int64(random.next() % 50_000_000), expectedBytes: 90_000_000,
                lastPlayedAt: epoch, updatedAt: epoch, failureReason: state == .failed ? "network_lost" : nil, retryCount: 1))
            counts.downloads += 1
            if state == .availableOffline {
                try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                    id: "offline-\(itemId)", itemId: itemId, category: .podcast, relativePath: "Podcasts/\(itemId).mp3",
                    byteCount: 60_000_000, checksumSHA256: String(repeating: "e", count: 64), isReproducible: false,
                    protections: [], lastAccessedAt: epoch, createdAt: epoch))
                counts.offlineAssets += 1
            }
        }

        // Prepared audio: a manifest (with its chunks) for every 4th article, an asset beside it, a job for the newest few.
        var manifestIds: [(itemId: String, manifestId: String)] = []
        for (position, itemId) in articles.enumerated() where position % 4 == 0 {
            let text = try store.loadItem(id: itemId).text ?? ""
            let chunkCount = max(4, text.utf8.count / 1_500)
            let manifestId = "manifest-\(itemId)"
            let chunks = (0..<chunkCount).map { index in
                PreparedAudioChunk(
                    id: "\(manifestId)-chunk-\(index)", index: index,
                    sourceRange: SourceLocator(documentId: itemId, segmentId: "p\(index)", utf8Start: index * 1_500, utf8End: (index + 1) * 1_500),
                    relativePath: "Prepared/\(itemId)/chunk-\(index).m4a", byteCount: 180_000,
                    checksumSHA256: String(repeating: "f", count: 64), durationMs: 20_000, committedAt: epoch, engine: "kitten")
            }
            try store.savePreparedAudioManifest(PreparedAudioManifest(
                id: manifestId, itemId: itemId, sourcePackageId: "canonical-\(itemId)", signature: signature,
                state: .readyOffline, plannedChunkCount: chunkCount, chunks: chunks,
                artifact: PreparedAudioArtifact(relativePath: "Prepared/\(itemId).m4a", byteCount: Int64(chunkCount) * 180_000,
                                                checksumSHA256: String(repeating: "9", count: 64), durationMs: chunkCount * 20_000),
                createdAt: epoch, updatedAt: epoch, articleIdentity: "identity-\(itemId)"))
            try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
                id: "offline-\(manifestId)", itemId: itemId, category: .preparedAudio, relativePath: "Prepared/\(itemId).m4a",
                byteCount: Int64(chunkCount) * 180_000, checksumSHA256: String(repeating: "9", count: 64), isReproducible: true,
                lastAccessedAt: epoch, createdAt: epoch))
            counts.manifests += 1
            counts.offlineAssets += 1
            manifestIds.append((itemId, manifestId))
        }
        for (index, entry) in manifestIds.suffix(max(2, scale.items / 25)).enumerated() {
            try store.saveAudioPreparationJob(AudioPreparationJob(
                id: "prep-job-\(index)", itemId: entry.itemId, manifestId: entry.manifestId, policy: .whileCharging,
                requestedAt: epoch.addingTimeInterval(Double(index)), userPriority: index % 3 == 0 ? 1 : nil, nextChunkIndex: 2))
            counts.preparationJobs += 1
        }
        for index in 0..<max(1, scale.items / 100) {
            try store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(
                id: "map-job-\(index)", itemId: itemIds[(index + 1) % podcasts], policy: .demandWindow,
                requestedAt: epoch, stage: .transcribe, nextUnitIndex: 3))
            counts.episodeMapJobs += 1
        }
        for index in stride(from: 0, to: scale.sessions, by: 10) {
            try store.saveAIJob(AIJob(
                id: "ai-job-\(index)", kind: "summary", itemId: nil, sessionId: "session-\(index)", turnId: "turn-session-\(index)",
                providerType: "local", model: "on-device", status: "complete", attempts: 1, lastError: nil,
                messages: [LibraryFixture.prose(bytes: 600, random: &random)], playbackMode: nil))
            counts.aiJobs += 1
        }
        try store.saveOfflineStorageBudget(OfflineStorageBudget())
        for index in 0..<2 {
            try store.saveOfflineStorageReservation(OfflineStorageReservation(
                id: "reservation-\(index)", ownerId: "prep-job-\(index)", byteCount: 5_000_000, createdAt: epoch,
                expiresAt: epoch.addingTimeInterval(3_600)))
            counts.reservations += 1
        }

        // Article sources: canonical packages (every 2nd) and structured documents (every 6th) hold the whole text.
        for (position, itemId) in articles.enumerated() where position % 2 == 0 || position % 6 == 0 {
            let text = try store.loadItem(id: itemId).text ?? ""
            let paragraphs = Self.paragraphs(of: text, size: 600)
            if position % 2 == 0 {
                try store.saveCanonicalSource(CanonicalSourcePackage(
                    id: "canonical-\(itemId)", itemId: itemId, sourceDocumentId: "doc-\(itemId)", format: .plainText,
                    title: "Item", navigation: [], segments: paragraphs.map {
                        SpeakableSegment(id: "s\($0.index)", text: $0.text,
                                         locator: SourceLocator(documentId: "doc-\(itemId)", segmentId: "s\($0.index)", utf8Start: $0.start, utf8End: $0.start + $0.text.utf8.count))
                    }, createdAt: epoch))
                counts.canonicalSources += 1
            }
            if position % 6 == 0 {
                try store.saveStructuredDocument(StructuredDocument(
                    extraction: .init(engine: "pdfkit", version: 1, sourceSHA256: String(repeating: "1", count: 64), pageCount: max(1, text.count / 3_000), textSHA256: nil),
                    text: text,
                    segments: paragraphs.map { .init(id: "seg-\($0.index)", role: $0.index == 0 ? .title : .body, range: .init(start: $0.start, length: $0.text.count), pageIndex: $0.index / 5) },
                    markers: paragraphs.prefix(40).map { .init(kind: .citation, range: .init(start: $0.start, length: 3), label: "[\($0.index)]") },
                    floats: []), itemId: itemId)
                counts.structuredDocuments += 1
            }
        }

        // Imported shared Margins: one layer per 4 followed sources, 12 Margins each, on distinct articles.
        for index in 0..<max(1, scale.sources / 4) {
            let itemId = articles[(index * 5) % articles.count]
            let layer = ImportedCommentaryLayer(
                id: "layer-\(index)", itemId: itemId, packageDigest: "digest-\(index)", packageId: "package-\(index)",
                itemIdentity: SharedItemIdentity(itemType: .text, title: "Item", durationMs: nil), importedAt: epoch)
            let margins = (0..<12).map { n in
                ImportedCommentaryInterjection(
                    id: "imported-\(index)-\(n)", layerId: layer.id, packageScopedId: "m\(n)", createdAt: epoch,
                    anchorEvidence: PortableAnchorEvidence(anchorType: .text, startChar: n * 100, endChar: n * 100 + 20),
                    approvedTranscript: LibraryFixture.prose(bytes: 220, random: &random))
            }
            _ = try store.importCommentaryLayer(layer, interjections: margins)
            counts.layers += 1
            counts.sharedMargins += margins.count
        }

        // The mapped podcast's episode-map artifacts (Skim, Timeline): a projection, proposals, a spine and a sketch.
        let mapped = LibraryFixture.mappedItemId
        let sceneMs = LibraryFixture.mappedDurationMs / LibraryFixture.mappedSceneCount
        try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
            id: "projection-mapped", itemId: mapped, createdAt: epoch,
            points: (0..<200).map { ResolvedListeningMapPoint(id: "pt-\($0)", sourceMediaTimeMs: $0 * 23_000, recipientMediaTimeMs: $0 * 23_000 + 400, confidence: .verified, evidenceIds: ["ev-\($0)"]) },
            intervals: (0..<LibraryFixture.mappedSceneCount).map {
                ResolvedListeningMapInterval(id: "iv-\($0)", sourceStartMs: $0 * sceneMs, sourceEndMs: ($0 + 1) * sceneMs, recipientStartMs: $0 * sceneMs, recipientEndMs: ($0 + 1) * sceneMs, isStable: true, reason: "verified")
            }))
        for proposal in 0..<2 {
            try store.savePortableListeningMapProposal(PortableListeningMapProposalArtifact(
                id: "proposal-\(proposal)", createdAt: epoch, generator: "fixture",
                scenes: (0..<LibraryFixture.mappedSceneCount).map {
                    PortableListeningMapScene(
                        id: "scene-\($0)", order: $0, title: "Scene \($0)", summaryText: LibraryFixture.prose(bytes: 300, random: &random),
                        eligibility: .eligible, startAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: $0 * sceneMs),
                        endAnchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ($0 + 1) * sceneMs))
                }), itemId: mapped)
        }
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: "spine-mapped", itemId: mapped, canonicalURL: "https://example.com/mapped", createdAt: epoch,
            landmarks: (0..<40).map {
                EpisodeFingerprintLandmark(id: "lm-\($0)", order: $0, sourceMediaStartMs: $0 * 115_000, sourceMediaEndMs: $0 * 115_000 + 12_000,
                                           anchorMediaTimeMs: $0 * 115_000 + 6_000, continuityEpoch: 0, trigger: .periodicPlayback,
                                           provenance: .observedDecodedPlayback, signatureAssetId: "sig-\($0)")
            }))
        try store.saveTranscriptPhraseSketch(TranscriptPhraseSketchArtifact(
            id: "sketch-mapped", itemId: mapped, saltBase64: "c2FsdA==", createdAt: epoch,
            windows: (0..<154).map { window in
                TranscriptPhraseSketchWindow(id: "w-\(window)", sourceStartMs: window * 30_000, sourceEndMs: (window + 1) * 30_000,
                                             hashes: (0..<24).map { _ in String(random.next(), radix: 16) })
            }))

        // Other podcasts: publisher audio and community map uploads; a few collections; share revisions of the notes.
        for index in 1..<min(3, podcasts) {
            try store.savePublisherAudio(PublisherAudio(itemId: itemIds[index], audioURL: "https://cdn.example.com/\(index).mp3", durationMs: 3_000_000, detectedFrom: "rss"))
            counts.publisherAudio += 1
            try store.saveCommunityMapUpload(CommunityMapUploadRecord(id: "upload-\(index)", itemId: itemIds[index], state: .uploaded, attempts: 1, lastAttemptAt: epoch, lastOutcome: "202"))
            counts.communityUploads += 1
        }
        for index in 0..<4 {
            try store.saveItemCollection(ItemCollection(id: "collection-\(index)", name: "Collection \(index)", itemIDs: Array(articles.prefix(20 + index)), createdAt: epoch))
            counts.collections += 1
        }
        for index in 1...min(6, scale.notes) {
            try store.saveInterjectionShareRevision(InterjectionShareRevision(
                id: "revision-\(index)", interjectionId: "note-\(index)", itemId: itemIds[(index * 7) % itemIds.count], sessionId: "session-\(index)",
                createdAt: epoch, approvedTranscript: LibraryFixture.prose(bytes: 200, random: &random), anchorBefore: "", anchorAfter: ""))
            counts.shareRevisions += 1
        }
        for index in 0..<scale.sources {
            try store.saveFeedRefreshState(FeedRefreshState(id: "refresh-\(index)", subscriptionId: "feed-\(index)", status: .succeeded, checkedAt: epoch, redactedHost: "example.com"))
            if index % 5 == 0 {
                try store.saveSourceSuggestionDecision(SourceSuggestionDecision(id: "decision-\(index)", sourceId: "source-\(index)", decision: .notNow, decidedAt: epoch))
            }
        }
        return counts
    }

    /// `text` cut into runs of about `size` bytes at spaces, with each run's UTF-8 start: the shape of an extracted article.
    static func paragraphs(of text: String, size: Int) -> [(index: Int, start: Int, text: String)] {
        var result: [(index: Int, start: Int, text: String)] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            var end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let space = text[end...].firstIndex(of: " ") { end = space }
            let piece = String(text[start..<end])
            result.append((result.count, offset, piece))
            offset += piece.utf8.count
            start = end
        }
        return result
    }
}
